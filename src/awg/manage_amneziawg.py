#!/usr/bin/env python3
# ==============================================================================
# manage_amneziawg.py — Universal AmneziaWG Controller & CLI Management Interface
#
# Provides automated peer provisioning, telemetry, and profile generation
# (supporting AmneziaWG 3.1 with obfuscation headers and v2.0 profiles).
#
# Based on architectural concepts and client configuration workflows from:
#   - AmneziaWG Installer by @bivlked: https://github.com/bivlked/amneziawg-installer
#   - Official AmneziaWG protocol specifications (v3.1 / v2.0)
# ==============================================================================

import sys
import os
import re
import json
import zlib
import time
import struct
import base64
import secrets
import shutil
import tarfile
import contextlib
import subprocess
import ipaddress
from datetime import datetime, timezone, timedelta
from pathlib import Path

# --- Execution Environment Detection (Container vs Host) ---
def detect_container_name():
    env_name = os.environ.get("AWG_CONTAINER_NAME")
    if env_name:
        return env_name
    if not shutil.which("docker"):
        return None
    res = subprocess.run("docker ps --format '{{.Names}}' 2>/dev/null", shell=True, capture_output=True, text=True)
    names = [n.strip() for n in res.stdout.splitlines() if n.strip()]
    for cand in ("amnezia-awg2", "amnezia-awg", "awg-server"):
        if cand in names:
            return cand
    for n in names:
        if "amnezia" in n or "awg" in n:
            return n
    return None

def detect_execution_mode():
    env_mode = os.environ.get("AWG_MODE", "").strip().lower()
    if env_mode in ("container", "docker"):
        cand = detect_container_name() or "amnezia-awg2"
        return "container", cand
    if env_mode in ("host", "native", "baremetal"):
        return "host", None

    cand = detect_container_name()
    if cand:
        res = subprocess.run(f"docker inspect -f '{{{{.State.Running}}}}' {cand} 2>/dev/null", shell=True, capture_output=True, text=True)
        if res.returncode == 0 and res.stdout.strip() == "true":
            return "container", cand

    if shutil.which("awg") or Path("/etc/amnezia/amneziawg/awg0.conf").exists():
        return "host", None

    return "container", (cand or "amnezia-awg2")

EXEC_MODE, CONTAINER = detect_execution_mode()
AWG_DIR = Path(os.environ.get("AWG_DIR", "/root/awg"))
try:
    AWG_DIR.mkdir(parents=True, exist_ok=True)
except (PermissionError, OSError):
    pass

# --- Atomic File Locking (Concurrency Protection) ---
@contextlib.contextmanager
def file_lock(lock_name="awg_config", timeout=30):
    lock_file = AWG_DIR / f".{lock_name}.lock"
    try:
        lock_file.parent.mkdir(parents=True, exist_ok=True)
    except Exception:
        pass

    try:
        import fcntl
        with open(lock_file, "w") as f:
            start_time = time.time()
            acquired = False
            while time.time() - start_time < timeout:
                try:
                    fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    acquired = True
                    break
                except (BlockingIOError, IOError):
                    time.sleep(0.1)
            if not acquired:
                raise TimeoutError(f"Timeout waiting for {lock_name} lock ({timeout}s)")
            try:
                yield
            finally:
                try:
                    fcntl.flock(f.fileno(), fcntl.LOCK_UN)
                except Exception:
                    pass
    except ImportError:
        # Non-POSIX environments (Windows dev/tests)
        yield

def get_conf_path():
    env_path = os.environ.get("AWG_CONF_PATH")
    if env_path:
        return env_path
    if EXEC_MODE == "container":
        return "/opt/amnezia/awg/awg0.conf"
    if Path("/etc/amnezia/amneziawg/awg0.conf").exists():
        return "/etc/amnezia/amneziawg/awg0.conf"
    return "/opt/amnezia/awg/awg0.conf"

def get_clients_table_path():
    env_path = os.environ.get("AWG_TABLE_PATH")
    if env_path:
        return env_path
    if EXEC_MODE == "container":
        return "/opt/amnezia/awg/clientsTable"
    return str(AWG_DIR / "clientsTable.json")

def run_cmd(cmd, check=False, input_data=None):
    res = subprocess.run(cmd, shell=True, capture_output=True, text=True, input=input_data)
    if check and res.returncode != 0:
        raise RuntimeError(f"Command failed ({res.returncode}): {cmd}\nstderr: {res.stderr}\nstdout: {res.stdout}")
    return res.stdout.strip(), res.stderr.strip(), res.returncode

def read_backend_file(path_str):
    p = Path(path_str)
    if p.exists():
        try:
            return p.read_text(encoding="utf-8")
        except Exception:
            pass
    if EXEC_MODE == "container" and CONTAINER:
        stdout, _, rc = run_cmd(f"docker exec {CONTAINER} cat {path_str}")
        if rc == 0:
            return stdout
    return ""

def write_backend_file(path_str, content):
    p = Path(path_str)
    written = False
    if EXEC_MODE == "container" and CONTAINER:
        _, stderr, rc = run_cmd(f"docker exec -i {CONTAINER} tee {path_str} >/dev/null", input_data=content)
        if rc == 0:
            written = True
        elif p.parent.exists():
            try:
                p.write_text(content, encoding="utf-8")
                written = True
            except Exception as exc:
                stderr = f"{stderr}; host write error: {exc}"
        if not written:
            raise IOError(f"Failed to write file {path_str} (container rc={rc}, stderr={stderr})")
    else:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")

def append_backend_file(path_str, content):
    p = Path(path_str)
    appended = False
    if EXEC_MODE == "container" and CONTAINER:
        _, stderr, rc = run_cmd(f"docker exec -i {CONTAINER} tee -a {path_str} >/dev/null", input_data=content)
        if rc == 0:
            appended = True
        elif p.exists():
            try:
                with open(p, "a", encoding="utf-8") as f:
                    f.write(content)
                appended = True
            except Exception as exc:
                stderr = f"{stderr}; host append error: {exc}"
        if not appended:
            raise IOError(f"Failed to append to file {path_str} (container rc={rc}, stderr={stderr})")
    else:
        with open(p, "a", encoding="utf-8") as f:
            f.write(content)

# --- Configuration & Obfuscation Parameters ---
def get_conf_params():
    conf = read_backend_file(get_conf_path())
    params = {}
    for key in [
        "ListenPort", "HeaderProtectionKey", "Jc", "Jmin", "Jmax",
        "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4",
        "I1", "I2", "I3", "I4", "I5", "Address", "MTU",
        "RandomTrailers", "DisableCookies", "PrimaryDns", "SecondaryDns",
        "RekeyAfterTime", "RekeyTimeout", "RejectAfterTime",
        "KeepaliveTimeout", "MaxHandshakeAttempts", "PersistentKeepalive",
        "ContentPaddingAddition", "CPA"
    ]:
        m = re.search(rf"^\s*{key}\s*=\s*(.+)$", conf, re.MULTILINE | re.IGNORECASE)
        if m:
            params[key] = m.group(1).strip()
    return params

CONF_PARAMS = get_conf_params()

SERVER_HOST = os.environ.get("SERVER_PUBLIC_HOST", "") or os.environ.get("WAN_IP", "")
if not SERVER_HOST:
    try:
        import urllib.request
        SERVER_HOST = urllib.request.urlopen("https://api.ipify.org", timeout=2).read().decode('utf-8').strip()
    except Exception:
        SERVER_HOST = "127.0.0.1"

SERVER_PORT = os.environ.get("SERVER_PORT") or os.environ.get("AWG_SERVER_PORT") or CONF_PARAMS.get("ListenPort") or "8443"
CLIENT_MTU = os.environ.get("CLIENT_MTU") or CONF_PARAMS.get("MTU") or "1280"

HEADER_PROTECTION_KEY = (
    os.environ.get("HEADER_PROTECTION_KEY")
    or os.environ.get("AWG_HEADER_PROTECTION_KEY")
    or CONF_PARAMS.get("HeaderProtectionKey")
    or ""
)

PRIMARY_DNS = os.environ.get("AWG_PRIMARY_DNS") or CONF_PARAMS.get("PrimaryDns") or "9.9.9.9"
SECONDARY_DNS = os.environ.get("AWG_SECONDARY_DNS") or CONF_PARAMS.get("SecondaryDns") or "76.76.2.0"

# Pre-defined DNS Profiles
DNS_PROFILES = {
    "quad9": "9.9.9.9, 149.112.112.112",
    "cloudflare": "1.1.1.1, 1.0.0.1",
    "controld": "76.76.2.2, 76.76.10.2",
    "adguard": "94.140.14.14, 94.140.15.15",
    "google": "8.8.8.8, 8.8.4.4",
    "local": "10.8.0.1",
    "default": f"{PRIMARY_DNS}, {SECONDARY_DNS}"
}

def resolve_dns(dns_key: str = "default") -> tuple[str, str]:
    target = DNS_PROFILES.get(dns_key.lower()) if dns_key else None
    if not target:
        if "," in dns_key:
            parts = [p.strip() for p in dns_key.split(",", 1)]
            return parts[0], parts[1]
        elif dns_key and ("." in dns_key or ":" in dns_key):
            return dns_key.strip(), SECONDARY_DNS
        target = DNS_PROFILES["default"]
    parts = [p.strip() for p in target.split(",", 1)]
    return parts[0], (parts[1] if len(parts) > 1 else SECONDARY_DNS)

raw_rt = os.environ.get("AWG_RANDOM_TRAILERS") or CONF_PARAMS.get("RandomTrailers") or "on"
RANDOM_TRAILERS = "on" if str(raw_rt).strip().lower() in ("on", "true", "1", "yes") else "off"

raw_dc = os.environ.get("AWG_DISABLE_COOKIES") or CONF_PARAMS.get("DisableCookies") or "off"
DISABLE_COOKIES = "on" if str(raw_dc).strip().lower() in ("on", "true", "1", "yes") else "off"

def_jc = CONF_PARAMS.get("Jc")
if def_jc in (None, "", "0"):
    def_jc = "4"
JC = os.environ.get("JC") or def_jc

def_jmin = CONF_PARAMS.get("Jmin")
if def_jmin in (None, "", "0"):
    def_jmin = "40"
JMIN = os.environ.get("JMIN") or def_jmin

def_jmax = CONF_PARAMS.get("Jmax")
if def_jmax in (None, "", "0"):
    def_jmax = "70"
JMAX = os.environ.get("JMAX") or def_jmax
S1 = os.environ.get("S1") or CONF_PARAMS.get("S1", "16")
S2 = os.environ.get("S2") or CONF_PARAMS.get("S2", "16")
S3 = os.environ.get("S3") or CONF_PARAMS.get("S3", "16")
S4 = os.environ.get("S4") or CONF_PARAMS.get("S4", "16")
H1 = os.environ.get("H1") or CONF_PARAMS.get("H1", "1")
H2 = os.environ.get("H2") or CONF_PARAMS.get("H2", "2")
H3 = os.environ.get("H3") or CONF_PARAMS.get("H3", "3")
H4 = os.environ.get("H4") or CONF_PARAMS.get("H4", "4")
DNS_I1_TEMPLATE = "<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>"
raw_i1 = os.environ.get("I1") or os.environ.get("AWG_I1") or CONF_PARAMS.get("I1", "")
I1 = DNS_I1_TEMPLATE if str(raw_i1).strip().lower() == "dns" else raw_i1
I2 = os.environ.get("I2") or CONF_PARAMS.get("I2", "")
I3 = os.environ.get("I3") or CONF_PARAMS.get("I3", "")
I4 = os.environ.get("I4") or CONF_PARAMS.get("I4", "")
I5 = os.environ.get("I5") or CONF_PARAMS.get("I5", "")

REKEY_AFTER_TIME = os.environ.get("AWG_REKEY_AFTER_TIME") or CONF_PARAMS.get("RekeyAfterTime", "")
REKEY_TIMEOUT = os.environ.get("AWG_REKEY_TIMEOUT") or CONF_PARAMS.get("RekeyTimeout", "")
REJECT_AFTER_TIME = os.environ.get("AWG_REJECT_AFTER_TIME") or CONF_PARAMS.get("RejectAfterTime", "")
KEEPALIVE_TIMEOUT = os.environ.get("AWG_KEEPALIVE_TIMEOUT") or CONF_PARAMS.get("KeepaliveTimeout", "")
MAX_HANDSHAKE_ATTEMPTS = os.environ.get("AWG_MAX_HANDSHAKE_ATTEMPTS") or CONF_PARAMS.get("MaxHandshakeAttempts", "")
PERSISTENT_KEEPALIVE = os.environ.get("AWG_PERSISTENT_KEEPALIVE") or CONF_PARAMS.get("PersistentKeepalive", "25")
ALLOWED_IPS = os.environ.get("AWG_ALLOWED_IPS", "0.0.0.0/0")
CPA = os.environ.get("AWG_CPA") or os.environ.get("AWG_CONTENT_PADDING_ADDITION") or CONF_PARAMS.get("ContentPaddingAddition") or CONF_PARAMS.get("CPA", "")

def ensure_backend_networking():
    """Ensure TCPMSS clamping and proper MTU for network stability."""
    if EXEC_MODE == "container" and CONTAINER:
        run_cmd(f"docker exec {CONTAINER} iptables -t mangle -C FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || docker exec {CONTAINER} iptables -t mangle -A FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true")
        run_cmd(f"docker exec {CONTAINER} iptables -t mangle -C FORWARD -i awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || docker exec {CONTAINER} iptables -t mangle -A FORWARD -i awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true")
        run_cmd(f"docker exec {CONTAINER} ip link set mtu {CLIENT_MTU} dev awg0 2>/dev/null || true")
    else:
        run_cmd("iptables -t mangle -C FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true")
        run_cmd("iptables -t mangle -C FORWARD -i awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -i awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true")

P = 2**255 - 19
def clamp(k_bytes):
    b = bytearray(k_bytes)
    b[0] &= 248; b[31] &= 127; b[31] |= 64
    return int.from_bytes(b, "little")

def x25519(k, u=9):
    x1, x2, z2, x3, z3 = u, 1, 0, u, 1
    for i in range(254, -1, -1):
        bit = (k >> i) & 1
        if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
        A = (x2 + z2) % P; AA = (A * A) % P; B = (x2 - z2) % P; BB = (B * B) % P
        E = (AA - BB) % P; C = (x3 + z3) % P; D = (x3 - z3) % P
        x3 = pow(D * A + C * B, 2, P); z3 = (x1 * pow(D * A - C * B, 2, P)) % P
        x2 = (AA * BB) % P; z2 = (E * (AA + 121665 * E)) % P
        if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
    return (x2 * pow(z2, P - 2, P)) % P

def curve25519_pubkey(priv_b64):
    try:
        raw_priv = base64.b64decode(priv_b64)
        k = clamp(raw_priv)
        pub_raw = x25519(k, 9).to_bytes(32, "little")
        return base64.b64encode(pub_raw).decode()
    except Exception:
        return None

def generate_wg_keypair():
    priv_raw = os.urandom(32)
    k = clamp(priv_raw)
    pub_raw = x25519(k, 9).to_bytes(32, "little")
    return base64.b64encode(priv_raw).decode(), base64.b64encode(pub_raw).decode()

def get_server_pubkey():
    for cand_path in [
        "/opt/amnezia/awg/wireguard_server_public_key.key",
        "/etc/amnezia/amneziawg/server_public.key",
        str(AWG_DIR / "keys" / "server_public.key")
    ]:
        pub = read_backend_file(cand_path)
        if pub:
            return pub.strip()
    env_pub = os.environ.get("AWG_SERVER_PUBKEY")
    if env_pub:
        return env_pub

    conf = read_backend_file(get_conf_path())
    m = re.search(r"PrivateKey\s*=\s*(\S+)", conf)
    if m:
        priv = m.group(1)
        if EXEC_MODE == "container" and CONTAINER:
            stdout, _, rc = run_cmd(f"docker exec -i {CONTAINER} awg pubkey 2>/dev/null || echo '{priv}' | wg pubkey 2>/dev/null", input_data=priv)
        else:
            stdout, _, rc = run_cmd("awg pubkey 2>/dev/null || wg pubkey 2>/dev/null", input_data=priv)
        if rc == 0 and stdout:
            return stdout
        derived = curve25519_pubkey(priv)
        if derived:
            return derived
    raise RuntimeError("Server public key not found in AmneziaWG configuration")


def get_server_psk():
    for cand_path in [
        "/opt/amnezia/awg/wireguard_psk.key",
        "/etc/amnezia/amneziawg/wireguard_psk.key",
        str(AWG_DIR / "keys" / "server_psk.key")
    ]:
        psk = read_backend_file(cand_path)
        if psk:
            return psk.strip()
    env_psk = os.environ.get("AWG_SERVER_PSK")
    if env_psk:
        return env_psk

    conf = read_backend_file(get_conf_path())
    m = re.search(r"PresharedKey\s*=\s*(\S+)", conf)
    if m:
        return m.group(1).strip()
    return base64.b64encode(secrets.token_bytes(32)).decode('utf-8')

def load_clients_table():
    txt = read_backend_file(get_clients_table_path())
    if txt:
        try:
            return json.loads(txt)
        except Exception:
            return []
    return []

def save_clients_table(table):
    write_backend_file(get_clients_table_path(), json.dumps(table, indent=4, ensure_ascii=False))

def parse_duration(duration_str: str) -> timedelta | datetime | None:
    """Parses duration strings like '30d', '12h', '60m', or exact dates 'YYYY-MM-DD'."""
    if not duration_str or duration_str.strip().lower() in ("none", "never", "off", "0", ""):
        return None
    d_clean = duration_str.strip()

    # Match ISO date or YYYY-MM-DD
    if re.match(r'^\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}:\d{2})?$', d_clean):
        try:
            if "T" in d_clean:
                dt = datetime.fromisoformat(d_clean)
            elif " " in d_clean:
                dt = datetime.strptime(d_clean, "%Y-%m-%d %H:%M:%S")
            else:
                dt = datetime.strptime(d_clean, "%Y-%m-%d")
            return dt.replace(tzinfo=timezone.utc)
        except Exception:
            pass

    m = re.match(r'^(\d+)\s*([dhms])$', d_clean.lower())
    if m:
        val = int(m.group(1))
        unit = m.group(2)
        if unit == "d":
            return timedelta(days=val)
        elif unit == "h":
            return timedelta(hours=val)
        elif unit == "m":
            return timedelta(minutes=val)
        elif unit == "s":
            return timedelta(seconds=val)
    return None

def encode_amnezia_vpnuri_31(
    conf_text: str, client_ip: str, client_priv: str, client_pub: str,
    description: str = "AmneziaWG 3.1",
    dns1: str = PRIMARY_DNS, dns2: str = SECONDARY_DNS
) -> str:
    internal_config = conf_text
    server_pub = None
    server_psk = None
    server_host = SERVER_HOST
    server_port = SERVER_PORT

    if internal_config:
        m_pub = re.search(r"^\s*PublicKey\s*=\s*(\S+)", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_pub:
            server_pub = m_pub.group(1).strip()
        m_psk = re.search(r"^\s*PresharedKey\s*=\s*(\S+)", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_psk:
            server_psk = m_psk.group(1).strip()
        m_ep = re.search(r"^\s*Endpoint\s*=\s*([^:\s]+):(\d+)", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_ep:
            server_host = m_ep.group(1).strip()
            server_port = m_ep.group(2).strip()

    if not server_pub:
        server_pub = get_server_pubkey()
    if not server_psk:
        server_psk = get_server_psk()

    try:
        port_int = int(server_port)
    except ValueError:
        port_int = 8443

    # Единый источник конфигурации: используем переданный conf_text
    if not internal_config:
        internal_config = f"""[Interface]
Address = {client_ip}/32
DNS = {dns1}, {dns2}
PrivateKey = {client_priv}
MTU = {CLIENT_MTU}
Jc = {JC}
Jmin = {JMIN}
Jmax = {JMAX}
S1 = {S1}
S2 = {S2}
S3 = {S3}
S4 = {S4}
H1 = {H1}
H2 = {H2}
H3 = {H3}
H4 = {H4}
""" + (f"I1 = {I1}\n" if I1 else "") + (f"HeaderProtectionKey = {HEADER_PROTECTION_KEY}\n" if HEADER_PROTECTION_KEY else "") + (f"ContentPaddingAddition = {CPA}\n" if CPA else "") + f"""RekeyAfterTime = {REKEY_AFTER_TIME}
RekeyTimeout = {REKEY_TIMEOUT}
RejectAfterTime = {REJECT_AFTER_TIME}
KeepaliveTimeout = {KEEPALIVE_TIMEOUT}
MaxHandshakeAttempts = {MAX_HANDSHAKE_ATTEMPTS}
RandomTrailers = {RANDOM_TRAILERS}
DisableCookies = {DISABLE_COOKIES}

[Peer]
PublicKey = {server_pub}
PresharedKey = {server_psk}
AllowedIPs = {ALLOWED_IPS}
Endpoint = {SERVER_HOST}:{SERVER_PORT}
PersistentKeepalive = {PERSISTENT_KEEPALIVE}
"""

    proto_ver = "3.1" if HEADER_PROTECTION_KEY else "2.0"
    if not HEADER_PROTECTION_KEY and "3.1" in description:
        description = description.replace("3.1", "2.0")

    cur_i1 = I1
    cur_jc = JC
    cur_jmin = JMIN
    cur_jmax = JMAX
    cur_mtu = str(CLIENT_MTU)
    cur_keepalive = str(PERSISTENT_KEEPALIVE)
    cur_allowed = ALLOWED_IPS

    if internal_config:
        m_i1 = re.search(r"^\s*I1\s*=\s*(.+)$", internal_config, re.MULTILINE | re.IGNORECASE)
        cur_i1 = m_i1.group(1).strip() if m_i1 else ""

        m_jc = re.search(r"^\s*Jc\s*=\s*(\d+)", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_jc:
            cur_jc = m_jc.group(1).strip()

        m_jmin = re.search(r"^\s*Jmin\s*=\s*(\d+)", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_jmin:
            cur_jmin = m_jmin.group(1).strip()

        m_jmax = re.search(r"^\s*Jmax\s*=\s*(\d+)", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_jmax:
            cur_jmax = m_jmax.group(1).strip()

        m_mtu = re.search(r"^\s*MTU\s*=\s*(\d+)", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_mtu:
            cur_mtu = m_mtu.group(1).strip()

        m_ka = re.search(r"^\s*PersistentKeepalive\s*=\s*(\d+)", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_ka:
            cur_keepalive = m_ka.group(1).strip()

        m_al = re.search(r"^\s*AllowedIPs\s*=\s*(.+)$", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_al:
            cur_allowed = m_al.group(1).strip()

    last_config_dict = {
        "DisableCookies": DISABLE_COOKIES,
        "H1": H1, "H2": H2, "H3": H3, "H4": H4,
        "HeaderProtectionKey": HEADER_PROTECTION_KEY,
        "I1": cur_i1, "I2": I2, "I3": I3, "I4": I4, "I5": I5,
        "Jc": cur_jc, "Jmax": cur_jmax, "Jmin": cur_jmin,
        "KeepaliveTimeout": KEEPALIVE_TIMEOUT, "MaxHandshakeAttempts": MAX_HANDSHAKE_ATTEMPTS,
        "RandomTrailers": RANDOM_TRAILERS, "RejectAfterTime": REJECT_AFTER_TIME,
        "RekeyAfterTime": REKEY_AFTER_TIME, "RekeyTimeout": REKEY_TIMEOUT,
        "S1": S1, "S2": S2, "S3": S3, "S4": S4,
        "allowed_ips": [ip.strip() for ip in cur_allowed.split(",") if ip.strip()],
        "clientId": client_pub, "client_ip": client_ip,
        "client_priv_key": client_priv, "client_pub_key": client_pub,
        "config": internal_config, "hostName": server_host,
        "mtu": str(cur_mtu), "persistent_keep_alive": cur_keepalive,
        "port": port_int, "psk_key": server_psk,
        "server_pub_key": server_pub
    }
    if CPA:
        last_config_dict["ContentPaddingAddition"] = CPA

    container_id = CONTAINER or "amnezia-awg"
    awg_dict = {
        "DisableCookies": DISABLE_COOKIES,
        "H1": H1, "H2": H2, "H3": H3, "H4": H4,
        "HeaderProtectionKey": HEADER_PROTECTION_KEY,
        "I1": cur_i1, "I2": I2, "I3": I3, "I4": I4, "I5": I5,
        "Jc": cur_jc, "Jmax": cur_jmax, "Jmin": cur_jmin,
        "KeepaliveTimeout": KEEPALIVE_TIMEOUT, "MaxHandshakeAttempts": MAX_HANDSHAKE_ATTEMPTS,
        "RandomTrailers": RANDOM_TRAILERS, "RejectAfterTime": REJECT_AFTER_TIME,
        "RekeyAfterTime": REKEY_AFTER_TIME, "RekeyTimeout": REKEY_TIMEOUT,
        "S1": S1, "S2": S2, "S3": S3, "S4": S4,
        "last_config": json.dumps(last_config_dict, ensure_ascii=False),
        "port": str(server_port), "protocol_version": proto_ver,
        "subnet_address": "10.8.0.0", "transport_proto": "udp"
    }
    if CPA:
        awg_dict["ContentPaddingAddition"] = CPA

    container_data = {
        "containers": [
            {
                "awg": awg_dict,
                "container": container_id
            }
        ],
        "defaultContainer": container_id,
        "description": description,
        "dns1": dns1, "dns2": dns2,
        "format_version": 1, "hostName": server_host
    }

    json_str = json.dumps(container_data, ensure_ascii=False)
    json_bytes = json_str.encode("utf-8")
    compressed = zlib.compress(json_bytes, 8)
    payload = struct.pack(">I", len(json_bytes)) + compressed
    encoded_b64 = base64.urlsafe_b64encode(payload).decode("utf-8").rstrip("=")
    return f"vpn://{encoded_b64}"

def check_status():
    ensure_backend_networking()
    if EXEC_MODE == "container" and CONTAINER:
        out, _, rc = run_cmd(f"docker inspect -f '{{{{.State.Running}}}}' {CONTAINER}")
        is_running = (rc == 0 and out.strip() == "true")
        if not is_running:
            return {"ok": False, "mode": EXEC_MODE, "status": "offline", "active": False, "error": f"Container {CONTAINER} is not running"}
        _, _, rc = run_cmd(f"docker exec {CONTAINER} ip link show awg0")
        if rc != 0:
            return {"ok": False, "mode": EXEC_MODE, "status": "offline", "active": False, "error": "Interface awg0 not found in container"}
    else:
        out, _, rc = run_cmd("ip link show awg0 2>/dev/null")
        if rc != 0:
            return {"ok": False, "mode": EXEC_MODE, "status": "offline", "active": False, "error": "Interface awg0 not found on host"}

    table = load_clients_table()
    try:
        p_int = int(SERVER_PORT)
    except ValueError:
        p_int = 8443

    now_iso = datetime.now(timezone.utc).isoformat()
    active_count = 0
    expired_count = 0
    for c in table:
        ud = c.get("userData", {})
        if ud.get("blocked", False):
            continue
        exp = ud.get("expiryDate")
        if exp and exp <= now_iso:
            expired_count += 1
        else:
            active_count += 1

    return {
        "ok": True,
        "mode": EXEC_MODE,
        "status": "online",
        "active": True,
        "service": {"unit": CONTAINER or "awg-quick@awg0", "active": True},
        "interface": {"name": "awg0", "present": True},
        "port": {"number": p_int, "proto": "udp", "listening": True},
        "clients": {
            "total": len(table),
            "active": active_count,
            "expired_pending": expired_count
        }
    }

def get_stats():
    ensure_backend_networking()
    if EXEC_MODE == "container" and CONTAINER:
        dump_out, _, rc = run_cmd(f"docker exec {CONTAINER} awg show awg0 dump")
    else:
        dump_out, _, rc = run_cmd("awg show awg0 dump 2>/dev/null")

    if rc != 0:
        return {"ok": False, "mode": EXEC_MODE, "error": "Failed to run awg show", "clients": [], "items": []}

    table = load_clients_table()
    data_by_pub = {item.get("clientId", "").strip(): item.get("userData", {}) for item in table}

    clients = []
    lines = dump_out.strip().splitlines()
    now_utc = datetime.now(timezone.utc)

    for line in lines[1:]:
        parts = line.strip().split()
        if len(parts) >= 7:
            pubkey = parts[0]
            endpoint = parts[2] if parts[2] != "(none)" else None
            allowed_ips = parts[3]
            handshake = int(parts[4]) if parts[4].isdigit() else 0
            rx = int(parts[5]) if parts[5].isdigit() else 0
            tx = int(parts[6]) if parts[6].isdigit() else 0
            
            ud = data_by_pub.get(pubkey, {})
            name = ud.get("clientName", pubkey)
            ip = allowed_ips.split("/")[0]

            exp_str = ud.get("expiryDate")
            days_left = None
            if exp_str:
                try:
                    exp_dt = datetime.fromisoformat(exp_str)
                    delta = exp_dt - now_utc
                    days_left = round(delta.total_seconds() / 86400.0, 1)
                except Exception:
                    pass

            clients.append({
                "name": name,
                "client_name": name,
                "public_key": pubkey,
                "ip": ip,
                "allowed_ips": allowed_ips,
                "latest_handshake": handshake,
                "rx_bytes": rx,
                "tx_bytes": tx,
                "endpoint": endpoint,
                "blocked": ud.get("blocked", False),
                "expiry_date": exp_str,
                "days_left": days_left
            })

    return {
        "ok": True,
        "mode": EXEC_MODE,
        "status": "online",
        "clients": clients,
        "items": clients,
        "total": len(clients)
    }

def find_next_ip():
    conf_content = read_backend_file(get_conf_path())
    table = load_clients_table()

    network = None
    server_ip = None
    m = re.search(r'^\s*Address\s*=\s*([0-9a-fA-F\.:]+(?:/\d+)?)(?:,.*)?$', conf_content, re.MULTILINE)
    if m:
        addr_str = m.group(1).strip()
        try:
            if "/" in addr_str:
                iface = ipaddress.ip_interface(addr_str)
                network = iface.network
                server_ip = iface.ip
            else:
                ip = ipaddress.ip_address(addr_str)
                network = ipaddress.ip_network(f"{ip}/24", strict=False)
                server_ip = ip
        except Exception:
            pass

    if not network:
        subnet_ip = os.environ.get("AWG_SUBNET_IP", "10.8.0.0")
        subnet_cidr = os.environ.get("AWG_SUBNET_CIDR", "22")
        try:
            network = ipaddress.ip_network(f"{subnet_ip}/{subnet_cidr}", strict=False)
            server_ip = network.network_address + 1
        except Exception:
            network = ipaddress.ip_network("10.8.0.0/22")
            server_ip = ipaddress.ip_address("10.8.0.1")

    used = set()
    used.add(str(network.network_address))
    used.add(str(network.broadcast_address))
    if server_ip:
        used.add(str(server_ip))

    for m in re.finditer(r'AllowedIPs\s*=\s*([0-9a-fA-F\.:]+)(?:/\d+)?', conf_content):
        used.add(m.group(1).strip())
    for item in table:
        a_ip = item.get("userData", {}).get("allowed_ips", "")
        m = re.search(r'([0-9a-fA-F\.:]+)(?:/\d+)?', a_ip)
        if m:
            used.add(m.group(1).strip())

    for host in network.hosts():
        ip_str = str(host)
        if ip_str not in used:
            return ip_str

    raise RuntimeError(f"No free IPs available in {network} subnet pool")

def is_valid_client_name(name):
    return bool(name and isinstance(name, str) and re.match(r'^[a-zA-Z0-9_-]{1,64}$', name))

def is_valid_pubkey(key):
    return bool(key and isinstance(key, str) and len(key) == 44 and re.match(r'^[A-Za-z0-9+/]{43}=$', key))

def is_valid_identifier(ident):
    return is_valid_client_name(ident) or is_valid_pubkey(ident)

def add_client(
    client_name: str,
    expires: str | None = None,
    dns_choice: str = "default",
    shred_privkey: bool = False,
    custom_i1: str | None = None,
    custom_jc: str | None = None,
    custom_jmin: str | None = None,
    custom_jmax: str | None = None,
    custom_mtu: str | None = None,
    custom_keepalive: str | None = None,
    custom_allowed_ips: str | None = None,
    custom_cpa: str | None = None,
    preset: str | None = None
):
    if not is_valid_client_name(client_name):
        return {"ok": False, "error": "Invalid client name. Use 1-64 alphanumeric characters, underscores, or dashes."}

    # Apply preset defaults if specified
    if preset:
        p_clean = preset.strip().lower()
        if p_clean in ("stealth", "mobile", "anti-dpi", "dpi"):
            if custom_i1 is None:
                custom_i1 = DNS_I1_TEMPLATE
            if custom_jc is None:
                custom_jc = "4"
            if custom_jmin is None:
                custom_jmin = "40"
            if custom_jmax is None:
                custom_jmax = "70"
            if custom_mtu is None:
                custom_mtu = "1280"
            if custom_cpa is None:
                custom_cpa = "16-64"
        elif p_clean in ("fast", "gaming", "game", "home", "router", "direct"):
            if custom_i1 is None:
                custom_i1 = ""
            if custom_jc is None:
                custom_jc = "0"
            if custom_jmin is None:
                custom_jmin = "0"
            if custom_jmax is None:
                custom_jmax = "0"
            if custom_mtu is None:
                custom_mtu = "1360"
        elif p_clean in ("base", "default", "standard"):
            if custom_i1 is None:
                custom_i1 = ""
            if custom_jc is None:
                custom_jc = "4"
            if custom_jmin is None:
                custom_jmin = "40"
            if custom_jmax is None:
                custom_jmax = "70"
            if custom_mtu is None:
                custom_mtu = "1280"

    client_mtu = str(custom_mtu).strip() if custom_mtu is not None else str(CLIENT_MTU)
    client_jc = str(custom_jc).strip() if custom_jc is not None else str(JC)
    client_jmin = str(custom_jmin).strip() if custom_jmin is not None else str(JMIN)
    client_jmax = str(custom_jmax).strip() if custom_jmax is not None else str(JMAX)
    client_keepalive = str(custom_keepalive).strip() if custom_keepalive is not None else str(PERSISTENT_KEEPALIVE)
    client_allowed_ips = str(custom_allowed_ips).strip() if custom_allowed_ips is not None else str(ALLOWED_IPS)

    target_i1 = custom_i1 if custom_i1 is not None else I1
    if target_i1 and target_i1.lower() == "dns":
        target_i1 = DNS_I1_TEMPLATE

    ensure_backend_networking()
    dns1, dns2 = resolve_dns(dns_choice)

    # Calculate expiration if specified
    exp_iso = None
    if expires:
        parsed_exp = parse_duration(expires)
        if isinstance(parsed_exp, timedelta):
            exp_iso = (datetime.now(timezone.utc) + parsed_exp).isoformat()
        elif isinstance(parsed_exp, datetime):
            exp_iso = parsed_exp.isoformat()

    with file_lock("awg_config"):
        table = load_clients_table()
        for item in table:
            if item.get("userData", {}).get("clientName") == client_name:
                remove_client(client_name)
                break

        client_ip = find_next_ip()
        if EXEC_MODE == "container" and CONTAINER:
            priv_out, _, _ = run_cmd(f"docker exec {CONTAINER} awg genkey", check=True)
            client_priv = priv_out.strip()
            pub_out, _, _ = run_cmd(f"docker exec -i {CONTAINER} awg pubkey", check=True, input_data=client_priv)
            client_pub = pub_out.strip()
        else:
            try:
                priv_out, _, _ = run_cmd("awg genkey 2>/dev/null || wg genkey 2>/dev/null", check=True)
                client_priv = priv_out.strip()
                pub_out, _, _ = run_cmd("awg pubkey 2>/dev/null || wg pubkey 2>/dev/null", check=True, input_data=client_priv)
                client_pub = pub_out.strip()
            except Exception:
                client_priv, client_pub = generate_wg_keypair()


        server_psk = get_server_psk()
        server_pub = get_server_pubkey()

        # Zero-Downtime Kernel Sync: Apply directly to active memory table
        psk_flag = ""
        if EXEC_MODE == "container" and CONTAINER:
            psk_flag = "preshared-key /opt/amnezia/awg/wireguard_psk.key "
            run_cmd(
                f"docker exec {CONTAINER} awg set awg0 peer {client_pub} {psk_flag}allowed-ips {client_ip}/32",
                check=True
            )
        else:
            for p_cand in ("/etc/amnezia/amneziawg/wireguard_psk.key", str(AWG_DIR / "keys" / "server_psk.key")):
                if Path(p_cand).exists():
                    psk_flag = f"preshared-key {p_cand} "
                    break
            run_cmd(f"awg set awg0 peer {client_pub} {psk_flag}allowed-ips {client_ip}/32", check=True)

        peer_block = (
            f"\n# client: {client_name}\n"
            f"[Peer]\n"
            f"PublicKey = {client_pub}\n"
            f"PresharedKey = {server_psk}\n"
            f"AllowedIPs = {client_ip}/32\n"
        )
        conf_path = get_conf_path()
        try:
            append_backend_file(conf_path, peer_block)
            table = load_clients_table()
            table.append({
                "clientId": client_pub,
                "userData": {
                    "allowed_ips": f"{client_ip}/32",
                    "clientName": client_name,
                    "creationDate": datetime.now(timezone.utc).isoformat(),
                    "expiryDate": exp_iso,
                    "dns": dns_choice,
                    "blocked": False,
                    "preset": preset or "custom",
                    "mtu": client_mtu,
                    "jc": client_jc,
                    "has_i1": bool(target_i1)
                }
            })
            save_clients_table(table)
        except Exception:
            if EXEC_MODE == "container" and CONTAINER:
                run_cmd(f"docker exec {CONTAINER} awg set awg0 peer {client_pub} remove 2>/dev/null || true")
            else:
                run_cmd(f"awg set awg0 peer {client_pub} remove 2>/dev/null || true")
            raise

        conf_lines = [
            "[Interface]",
            f"Address = {client_ip}/32",
            f"DNS = {dns1}, {dns2}",
            f"PrivateKey = {client_priv}",
            f"MTU = {client_mtu}",
            f"Jc = {client_jc}",
            f"Jmin = {client_jmin}",
            f"Jmax = {client_jmax}",
            f"S1 = {S1}",
            f"S2 = {S2}",
            f"S3 = {S3}",
            f"S4 = {S4}",
            f"H1 = {H1}",
            f"H2 = {H2}",
            f"H3 = {H3}",
            f"H4 = {H4}",
        ]
        if target_i1:
            conf_lines.append(f"I1 = {target_i1}")
        if I2:
            conf_lines.append(f"I2 = {I2}")
        if I3:
            conf_lines.append(f"I3 = {I3}")
        if I4:
            conf_lines.append(f"I4 = {I4}")
        if I5:
            conf_lines.append(f"I5 = {I5}")
        target_cpa = custom_cpa if custom_cpa is not None else CPA
        if target_cpa:
            conf_lines.append(f"ContentPaddingAddition = {target_cpa}")
        if HEADER_PROTECTION_KEY:
            conf_lines.append(f"HeaderProtectionKey = {HEADER_PROTECTION_KEY}")
        if REKEY_AFTER_TIME:
            conf_lines.append(f"RekeyAfterTime = {REKEY_AFTER_TIME}")
        if REKEY_TIMEOUT:
            conf_lines.append(f"RekeyTimeout = {REKEY_TIMEOUT}")
        if REJECT_AFTER_TIME:
            conf_lines.append(f"RejectAfterTime = {REJECT_AFTER_TIME}")
        if KEEPALIVE_TIMEOUT:
            conf_lines.append(f"KeepaliveTimeout = {KEEPALIVE_TIMEOUT}")
        if MAX_HANDSHAKE_ATTEMPTS:
            conf_lines.append(f"MaxHandshakeAttempts = {MAX_HANDSHAKE_ATTEMPTS}")
        conf_lines.extend([
            f"RandomTrailers = {RANDOM_TRAILERS}",
            f"DisableCookies = {DISABLE_COOKIES}",
            "",
            "[Peer]",
            f"PublicKey = {server_pub}",
            f"PresharedKey = {server_psk}",
            f"AllowedIPs = {client_allowed_ips}",
            f"Endpoint = {SERVER_HOST}:{SERVER_PORT}",
            f"PersistentKeepalive = {client_keepalive}",
            ""
        ])
        conf_content = "\n".join(conf_lines)

        conf_file = AWG_DIR / f"{client_name}.conf"
        conf_file.write_text(conf_content, encoding="utf-8")
        try:
            conf_file.chmod(0o600)
        except OSError:
            pass

        vpnuri = encode_amnezia_vpnuri_31(
            conf_content, client_ip, client_priv, client_pub,
            description=f"AmneziaWG - {client_name}",
            dns1=dns1, dns2=dns2
        )
        vpnuri_file = AWG_DIR / f"{client_name}.vpnuri"
        vpnuri_file.write_text(vpnuri, encoding="utf-8")
        try:
            vpnuri_file.chmod(0o600)
        except OSError:
            pass

        # Zero-Trust Shredding
        if shred_privkey:
            try:
                # Overwrite and remove local config file
                conf_file.write_bytes(secrets.token_bytes(len(conf_content)))
                conf_file.unlink(missing_ok=True)
            except Exception:
                pass

        return {
            "ok": True,
            "mode": EXEC_MODE,
            "status": "added",
            "client": client_name,
            "ip": client_ip,
            "public_key": client_pub,
            "preset": preset or "custom",
            "mtu": client_mtu,
            "jc": client_jc,
            "has_i1": bool(target_i1),
            "dns": f"{dns1}, {dns2}",
            "expires_at": exp_iso,
            "conf_file": str(conf_file) if not shred_privkey else None,
            "vpnuri_file": str(vpnuri_file),
            "vpnuri": vpnuri,
            "conf_content": conf_content if shred_privkey else None
        }

def remove_client(client_name):
    if not is_valid_identifier(client_name):
        return {"ok": False, "error": f"Invalid client identifier: '{client_name}'."}

    with file_lock("awg_config"):
        table = load_clients_table()
        pubkey = None
        canonical_name = None
        new_table = []
        for item in table:
            c_name = item.get("userData", {}).get("clientName")
            c_id = item.get("clientId")
            if c_name == client_name or c_id == client_name:
                pubkey = c_id
                canonical_name = c_name
            else:
                new_table.append(item)

        conf_text = read_backend_file(get_conf_path())
        if not pubkey and conf_text:
            m = re.search(r'# client:\s*' + re.escape(client_name) + r'\s*\n\[Peer\]\s*\nPublicKey\s*=\s*([^\s\n]+)', conf_text)
            if m:
                pubkey = m.group(1).strip()
                canonical_name = client_name
            elif is_valid_pubkey(client_name):
                pubkey = client_name

        if not canonical_name and is_valid_client_name(client_name):
            canonical_name = client_name

        save_clients_table(new_table)

        if pubkey:
            if EXEC_MODE == "container" and CONTAINER:
                run_cmd(f"docker exec {CONTAINER} awg set awg0 peer {pubkey} remove 2>/dev/null || true")
            else:
                run_cmd(f"awg set awg0 peer {pubkey} remove 2>/dev/null || true")

            if conf_text and pubkey in conf_text:
                pattern = r'(?m)(?:# client:[^\n]*\n)?\[Peer\]\s*\nPublicKey\s*=\s*' + re.escape(pubkey) + r'[\s\S]*?(?=\n(?:# client:|\[Peer\]|$))'
                content = re.sub(pattern, '', conf_text).strip() + "\n"
                write_backend_file(get_conf_path(), content)

        if canonical_name and is_valid_client_name(canonical_name):
            for ext in (".conf", ".vpnuri", ".png", ".vpnuri.png"):
                f = (AWG_DIR / f"{canonical_name}{ext}").resolve()
                try:
                    if f.is_relative_to(AWG_DIR.resolve()) and f.exists() and not f.is_symlink():
                        f.unlink()
                except Exception:
                    pass

        return {"ok": True, "mode": EXEC_MODE, "status": "removed", "client": client_name}

def block_client(client_name, reason="suspended"):
    if not is_valid_identifier(client_name):
        return {"ok": False, "error": f"Invalid client identifier: '{client_name}'"}

    with file_lock("awg_config"):
        table = load_clients_table()
        client_entry = None
        pubkey = None
        c_name = None
        ip = None
        for item in table:
            u_name = item.get("userData", {}).get("clientName")
            c_id = item.get("clientId")
            if u_name == client_name or c_id == client_name:
                client_entry = item
                pubkey = c_id
                c_name = u_name or client_name
                ip = item.get("userData", {}).get("allowed_ips")
                break

        conf_text = read_backend_file(get_conf_path())
        if not pubkey and conf_text:
            m = re.search(r'# client:\s*' + re.escape(client_name) + r'\s*\n\[Peer\]\s*\nPublicKey\s*=\s*([^\s\n]+)[\s\S]*?(?:AllowedIPs\s*=\s*([^\s\n]+))?', conf_text)
            if m:
                pubkey = m.group(1).strip()
                c_name = client_name
                if m.group(2) and not ip:
                    ip = m.group(2).strip()
            elif is_valid_pubkey(client_name):
                pubkey = client_name
                c_name = client_name

        if not pubkey:
            return {"ok": False, "error": f"Client '{client_name}' not found"}

        # Zero-Downtime: remove peer instantly from active interface
        if EXEC_MODE == "container" and CONTAINER:
            run_cmd(f"docker exec {CONTAINER} awg set awg0 peer {pubkey} remove 2>/dev/null || true")
        else:
            run_cmd(f"awg set awg0 peer {pubkey} remove 2>/dev/null || true")

        if conf_text and pubkey in conf_text:
            pattern = r'(?m)(?:# client:[^\n]*\n)?\[Peer\]\s*\nPublicKey\s*=\s*' + re.escape(pubkey) + r'[\s\S]*?(?=\n(?:# client:|\[Peer\]|$))'
            new_conf = re.sub(pattern, '', conf_text).strip() + "\n"
            write_backend_file(get_conf_path(), new_conf)

        if client_entry:
            client_entry.setdefault("userData", {})["blocked"] = True
            client_entry["userData"]["blockedReason"] = reason
            if ip and not client_entry["userData"].get("allowed_ips"):
                client_entry["userData"]["allowed_ips"] = ip
        else:
            table.append({
                "clientId": pubkey,
                "userData": {
                    "clientName": c_name or client_name,
                    "allowed_ips": ip or "",
                    "blocked": True,
                    "blockedReason": reason
                }
            })
        save_clients_table(table)
        return {"ok": True, "mode": EXEC_MODE, "status": "suspended", "client": client_name, "reason": reason}

def unblock_client(client_name, expires: str | None = None):
    if not is_valid_identifier(client_name):
        return {"ok": False, "error": f"Invalid client identifier: '{client_name}'"}

    with file_lock("awg_config"):
        table = load_clients_table()
        client_entry = None
        pubkey = None
        ip = None
        c_name = None
        for item in table:
            u_name = item.get("userData", {}).get("clientName")
            c_id = item.get("clientId")
            if u_name == client_name or c_id == client_name:
                client_entry = item
                pubkey = c_id
                ip = item.get("userData", {}).get("allowed_ips")
                c_name = u_name or client_name
                break

        conf_text = read_backend_file(get_conf_path())
        if not pubkey and conf_text:
            m = re.search(r'# client:\s*' + re.escape(client_name) + r'\s*\n\[Peer\]\s*\nPublicKey\s*=\s*([^\s\n]+)[\s\S]*?AllowedIPs\s*=\s*([^\s\n]+)', conf_text)
            if m:
                pubkey = m.group(1).strip()
                if not ip:
                    ip = m.group(2).strip()
                c_name = client_name
            elif is_valid_pubkey(client_name):
                pubkey = client_name
                c_name = client_name

        if not pubkey:
            return {"ok": False, "error": f"Client '{client_name}' not found"}
        if not ip:
            return {"ok": False, "error": f"IP address for client '{client_name}' not found"}

        psk_flag = ""
        if EXEC_MODE == "container" and CONTAINER:
            psk_flag = "preshared-key /opt/amnezia/awg/wireguard_psk.key "
            run_cmd(f"docker exec {CONTAINER} awg set awg0 peer {pubkey} {psk_flag}allowed-ips {ip}", check=True)
        else:
            for p_cand in ("/etc/amnezia/amneziawg/wireguard_psk.key", str(AWG_DIR / "keys" / "server_psk.key")):
                if Path(p_cand).exists():
                    psk_flag = f"preshared-key {p_cand} "
                    break
            run_cmd(f"awg set awg0 peer {pubkey} {psk_flag}allowed-ips {ip}", check=True)

        if pubkey not in conf_text:
            server_psk = get_server_psk()
            peer_block = (
                f"\n# client: {c_name or client_name}\n"
                f"[Peer]\n"
                f"PublicKey = {pubkey}\n"
                f"PresharedKey = {server_psk}\n"
                f"AllowedIPs = {ip}\n"
            )
            append_backend_file(get_conf_path(), peer_block)

        if client_entry:
            client_entry.setdefault("userData", {})["blocked"] = False
            client_entry["userData"]["blockedReason"] = None
            if expires:
                parsed_exp = parse_duration(expires)
                if isinstance(parsed_exp, timedelta):
                    client_entry["userData"]["expiryDate"] = (datetime.now(timezone.utc) + parsed_exp).isoformat()
                elif isinstance(parsed_exp, datetime):
                    client_entry["userData"]["expiryDate"] = parsed_exp.isoformat()
            save_clients_table(table)

        return {"ok": True, "mode": EXEC_MODE, "status": "unsuspended", "client": client_name}

def purge_expired():
    """Scans clientsTable and blocks expired peers without restarting the interface."""
    now_iso = datetime.now(timezone.utc).isoformat()
    table = load_clients_table()
    purged = []

    for item in table:
        ud = item.get("userData", {})
        if ud.get("blocked", False):
            continue
        exp = ud.get("expiryDate")
        if exp and exp <= now_iso:
            client_name = ud.get("clientName") or item.get("clientId")
            if client_name:
                res = block_client(client_name, reason="expired")
                if res.get("ok"):
                    purged.append(client_name)

    log_entry = f"[{datetime.now().strftime('%F %T')}] INFO: Purged expired clients: {purged if purged else 'none'}\n"
    try:
        with open(AWG_DIR / "manage_amneziawg.log", "a", encoding="utf-8") as f:
            f.write(log_entry)
    except Exception:
        pass

    return {
        "ok": True,
        "mode": EXEC_MODE,
        "status": "purged",
        "purged_count": len(purged),
        "purged_clients": purged
    }

def show_qr(client_name):
    """Outputs QR code for client .vpnuri or .conf."""
    uri_file = AWG_DIR / f"{client_name}.vpnuri"
    conf_file = AWG_DIR / f"{client_name}.conf"
    
    content = ""
    if uri_file.exists():
        content = uri_file.read_text(encoding="utf-8").strip()
    elif conf_file.exists():
        content = conf_file.read_text(encoding="utf-8").strip()
    else:
        return {"ok": False, "error": f"Profile for client '{client_name}' not found in {AWG_DIR}"}

    # Generate PNG if qrencode exists
    png_path = AWG_DIR / f"{client_name}.png"
    if shutil.which("qrencode"):
        run_cmd(f"qrencode -s 6 -l H -o '{png_path}' '{content}' 2>/dev/null || true")

    # Generate terminal ASCII QR
    ansi_qr = ""
    if shutil.which("qrencode"):
        stdout, _, rc = run_cmd(f"qrencode -t ANSIUTF8 '{content}' 2>/dev/null")
        if rc == 0 and stdout:
            ansi_qr = stdout

    return {
        "ok": True,
        "client": client_name,
        "qr_ascii": ansi_qr,
        "png_file": str(png_path) if png_path.exists() else None,
        "vpnuri": content if content.startswith("vpn://") else None
    }

def backup_configs():
    """Creates an atomic .tar.gz archive of all AWG configs, keys, and client tables."""
    backups_dir = AWG_DIR / "backups"
    backups_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    archive_path = backups_dir / f"awg_backup_{ts}.tar.gz"

    with file_lock("awg_backup"):
        with tarfile.open(archive_path, "w:gz") as tar:
            # 1. Server config
            conf_file = Path(get_conf_path())
            if conf_file.exists():
                tar.add(conf_file, arcname="server/awg0.conf")
            # 2. Clients table
            tbl_file = Path(get_clients_table_path())
            if tbl_file.exists():
                tar.add(tbl_file, arcname="clients/clientsTable.json")
            # 3. Keys directory
            keys_dir = AWG_DIR / "keys"
            if keys_dir.exists():
                tar.add(keys_dir, arcname="keys")
            # 4. Client profiles
            for ext in ("*.conf", "*.vpnuri"):
                for p in AWG_DIR.glob(ext):
                    tar.add(p, arcname=f"profiles/{p.name}")

    try:
        archive_path.chmod(0o600)
    except OSError:
        pass

    return {
        "ok": True,
        "mode": EXEC_MODE,
        "status": "backed_up",
        "archive": str(archive_path),
        "size_bytes": archive_path.stat().st_size
    }

def restore_configs(archive_path_str: str):
    """Safely restores configurations from a backup archive with path traversal checks."""
    archive_path = Path(archive_path_str)
    if not archive_path.is_file():
        return {"ok": False, "error": f"Backup archive not found: {archive_path}"}

    # Pre-extraction validation: ensure no path traversal or symlinks
    with tarfile.open(archive_path, "r:gz") as tar:
        for member in tar.getmembers():
            if member.name.startswith("/") or ".." in member.name or member.issym() or member.islnk():
                return {"ok": False, "error": f"Unsafe file path in archive: '{member.name}'. Restore aborted."}

    # Pre-restore snapshot of current state
    pre_snap = backup_configs()

    with file_lock("awg_config"):
        with tarfile.open(archive_path, "r:gz") as tar:
            for member in tar.getmembers():
                if member.name == "server/awg0.conf":
                    f = tar.extractfile(member)
                    if f:
                        write_backend_file(get_conf_path(), f.read().decode("utf-8"))
                elif member.name == "clients/clientsTable.json":
                    f = tar.extractfile(member)
                    if f:
                        write_backend_file(get_clients_table_path(), f.read().decode("utf-8"))
                elif member.name.startswith("profiles/"):
                    base = Path(member.name).name
                    f = tar.extractfile(member)
                    if f:
                        (AWG_DIR / base).write_bytes(f.read())
                        (AWG_DIR / base).chmod(0o600)

    # Sync running interface
    ensure_backend_networking()
    if EXEC_MODE == "container" and CONTAINER:
        run_cmd(f"docker restart {CONTAINER} 2>/dev/null || true")
    else:
        run_cmd("systemctl restart awg-quick@awg0 2>/dev/null || true")

    return {
        "ok": True,
        "mode": EXEC_MODE,
        "status": "restored",
        "restored_from": str(archive_path),
        "pre_restore_snapshot": pre_snap.get("archive")
    }

def get_client_uri(client_name: str):
    """Retrieves or regenerates the Amnezia vpn:// URI for a given client."""
    client_name = client_name.strip()
    if not is_valid_client_name(client_name):
        return {"ok": False, "mode": EXEC_MODE, "error": f"Invalid client name '{client_name}'."}

    uri_file = AWG_DIR / f"{client_name}.vpnuri"
    conf_file = AWG_DIR / f"{client_name}.conf"

    if uri_file.exists():
        uri = uri_file.read_text(encoding="utf-8").strip()
        if uri.startswith("vpn://"):
            return {
                "ok": True,
                "mode": EXEC_MODE,
                "client": client_name,
                "vpnuri": uri,
                "vpnuri_file": str(uri_file)
            }

    if conf_file.exists():
        conf_content = conf_file.read_text(encoding="utf-8")
        m_ip = re.search(r"^\s*Address\s*=\s*([^/,\s]+)", conf_content, re.MULTILINE | re.IGNORECASE)
        m_priv = re.search(r"^\s*PrivateKey\s*=\s*(\S+)", conf_content, re.MULTILINE | re.IGNORECASE)
        if m_ip and m_priv:
            c_ip = m_ip.group(1).strip()
            c_priv = m_priv.group(1).strip()
            c_pub = curve25519_pubkey(c_priv) or ""
            uri = encode_amnezia_vpnuri_31(
                conf_content, c_ip, c_priv, c_pub,
                description=f"AmneziaWG - {client_name}"
            )
            uri_file.write_text(uri, encoding="utf-8")
            try:
                uri_file.chmod(0o600)
            except OSError:
                pass
            return {
                "ok": True,
                "mode": EXEC_MODE,
                "client": client_name,
                "vpnuri": uri,
                "vpnuri_file": str(uri_file)
            }

    return {"ok": False, "mode": EXEC_MODE, "error": f"Client '{client_name}' configuration not found in {AWG_DIR}."}

# --- Main Entry Point with Universal JSON Exception Guard ---
def main():
    action = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "status"
    client_name = None
    expires = None
    dns_choice = "default"
    shred_privkey = False
    qr_mode = False
    custom_i1 = None
    custom_jc = None
    custom_jmin = None
    custom_jmax = None
    custom_mtu = None
    custom_keepalive = None
    custom_allowed_ips = None
    custom_cpa = None
    preset = None

    raw_mode = False

    args = sys.argv[1:]
    for arg in args:
        if arg.startswith("--expires="):
            expires = arg.split("=", 1)[1].strip()
        elif arg.startswith("--dns="):
            dns_choice = arg.split("=", 1)[1].strip()
        elif arg.startswith("--preset="):
            preset = arg.split("=", 1)[1].strip()
        elif arg.startswith("--mtu="):
            custom_mtu = arg.split("=", 1)[1].strip()
        elif arg.startswith("--cpa=") or arg.startswith("--content-padding="):
            custom_cpa = arg.split("=", 1)[1].strip()
        elif arg in ("--no-cpa", "--without-cpa"):
            custom_cpa = ""
        elif arg.startswith("--jc="):
            custom_jc = arg.split("=", 1)[1].strip()
        elif arg.startswith("--jmin="):
            custom_jmin = arg.split("=", 1)[1].strip()
        elif arg.startswith("--jmax="):
            custom_jmax = arg.split("=", 1)[1].strip()
        elif arg.startswith("--keepalive=") or arg.startswith("--persistent-keepalive="):
            custom_keepalive = arg.split("=", 1)[1].strip()
        elif arg.startswith("--allowed-ips="):
            custom_allowed_ips = arg.split("=", 1)[1].strip()
        elif arg == "--shred-privkey":
            shred_privkey = True
        elif arg in ("--raw", "-r"):
            raw_mode = True
        elif arg in ("--qr", "-q"):
            qr_mode = True
        elif arg in ("--i1", "--i1=dns", "--cps"):
            custom_i1 = DNS_I1_TEMPLATE
        elif arg.startswith("--i1="):
            val = arg.split("=", 1)[1].strip()
            custom_i1 = DNS_I1_TEMPLATE if val.lower() == "dns" else val
        elif arg in ("--no-i1", "--without-i1"):
            custom_i1 = ""
        elif not arg.startswith("-") and not client_name and arg != action:
            client_name = arg

    try:
        if action in ("status", "check", "info"):
            res = check_status()
        elif action in ("stats", "get-clients", "show", "list"):
            res = get_stats()
        elif action in ("uri", "vpnuri", "link", "get-uri"):
            res = get_client_uri(client_name or "client-1")
            if raw_mode and res.get("ok") and res.get("vpnuri"):
                print(res["vpnuri"])
                sys.exit(0)
        elif action == "add":
            res = add_client(
                client_name or "client-1",
                expires=expires,
                dns_choice=dns_choice,
                shred_privkey=shred_privkey,
                custom_i1=custom_i1,
                custom_jc=custom_jc,
                custom_jmin=custom_jmin,
                custom_jmax=custom_jmax,
                custom_mtu=custom_mtu,
                custom_keepalive=custom_keepalive,
                custom_allowed_ips=custom_allowed_ips,
                custom_cpa=custom_cpa,
                preset=preset
            )
            if qr_mode and res.get("ok"):
                qr_info = show_qr(res["client"])
                if qr_info.get("qr_ascii"):
                    print(qr_info["qr_ascii"], file=sys.stderr)
        elif action in ("remove", "del", "delete"):
            res = remove_client(client_name)
        elif action in ("block", "suspend", "disable"):
            res = block_client(client_name)
        elif action in ("unblock", "unsuspend", "enable"):
            res = unblock_client(client_name, expires=expires)
        elif action in ("purge-expired", "check-expired"):
            res = purge_expired()
        elif action in ("qr", "show-qr"):
            res = show_qr(client_name or "client-1")
            if res.get("ok") and res.get("qr_ascii"):
                print(res["qr_ascii"], file=sys.stderr)
            if raw_mode and res.get("ok") and res.get("vpnuri"):
                print(res["vpnuri"])
                sys.exit(0)
        elif action == "backup":
            res = backup_configs()
        elif action == "restore":
            res = restore_configs(client_name or "")
        elif action == "restart":
            if EXEC_MODE == "container" and CONTAINER:
                run_cmd(f"docker restart {CONTAINER}")
            else:
                run_cmd("systemctl restart awg-quick@awg0 2>/dev/null || true")
            res = {"ok": True, "mode": EXEC_MODE, "status": "restarted"}
        elif action in ("repair", "repair-module"):
            ensure_backend_networking()
            if EXEC_MODE == "container" and CONTAINER:
                run_cmd(f"docker start {CONTAINER} 2>/dev/null || true")
            else:
                run_cmd("systemctl start awg-quick@awg0 2>/dev/null || true")
            res = check_status()
        elif action in ("set-preset", "preset"):
            res = {"ok": True, "mode": EXEC_MODE, "status": "preset_applied"}
        else:
            res = get_stats()

        print(json.dumps(res, indent=2))

    except Exception as exc:
        # bivlked-style _json_exit_guard: Guarantee stdout always outputs valid JSON
        err_res = {
            "ok": False,
            "mode": EXEC_MODE,
            "command": action,
            "error": str(exc),
            "rc": 1
        }
        print(json.dumps(err_res, indent=2))
        sys.exit(1)

if __name__ == "__main__":
    main()
