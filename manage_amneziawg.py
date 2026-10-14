#!/usr/bin/env python3
# ==============================================================================
# manage_amneziawg.py — AmneziaWG Docker Controller & Adapter for awg_bot
# Compatible with AmneziaWG 3.1 inside Docker (amnezia-awg / amnezia-awg2)
# ==============================================================================
import sys
import os
import re
import json
import zlib
import struct
import base64
import secrets
import subprocess
from datetime import datetime, timezone
from pathlib import Path

# --- Container Auto-Detection ---
def detect_container_name():
    env_name = os.environ.get("AWG_CONTAINER_NAME")
    if env_name:
        return env_name
    res = subprocess.run("docker ps --format '{{.Names}}'", shell=True, capture_output=True, text=True)
    names = [n.strip() for n in res.stdout.splitlines() if n.strip()]
    for cand in ("amnezia-awg2", "amnezia-awg"):
        if cand in names:
            return cand
    for n in names:
        if "amnezia" in n or "awg" in n:
            return n
    return "amnezia-awg2"

CONTAINER = detect_container_name()
AWG_DIR = Path("/root/awg")
AWG_DIR.mkdir(parents=True, exist_ok=True)

def run_cmd(cmd, check=False, input_data=None):
    res = subprocess.run(cmd, shell=True, capture_output=True, text=True, input=input_data)
    if check and res.returncode != 0:
        raise RuntimeError(f"Command failed ({res.returncode}): {cmd}\nstderr: {res.stderr}\nstdout: {res.stdout}")
    return res.stdout.strip(), res.stderr.strip(), res.returncode

def read_container_file(path_str):
    p = Path(path_str)
    if p.exists():
        try:
            return p.read_text(encoding="utf-8")
        except Exception:
            pass
    stdout, _, rc = run_cmd(f"docker exec {CONTAINER} cat {path_str}")
    if rc == 0:
        return stdout
    return ""

def write_container_file(path_str, content):
    p = Path(path_str)
    if p.parent.exists():
        try:
            p.write_text(content, encoding="utf-8")
        except Exception:
            pass
    run_cmd(f"docker exec -i {CONTAINER} tee {path_str} >/dev/null", input_data=content, check=True)

def append_container_file(path_str, content):
    p = Path(path_str)
    if p.exists():
        try:
            with open(p, "a", encoding="utf-8") as f:
                f.write(content)
        except Exception:
            pass
    run_cmd(f"docker exec -i {CONTAINER} tee -a {path_str} >/dev/null", input_data=content, check=True)

# --- Configuration & Obfuscation Parameters ---
def get_conf_params():
    conf = read_container_file("/opt/amnezia/awg/awg0.conf")
    params = {}
    for key in [
        "ListenPort", "HeaderProtectionKey", "Jc", "Jmin", "Jmax",
        "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4", "I1", "Address"
    ]:
        m = re.search(rf"^\s*{key}\s*=\s*(.+)$", conf, re.MULTILINE)
        if m:
            params[key] = m.group(1).strip()
    return params

CONF_PARAMS = get_conf_params()

SERVER_HOST = os.environ.get("SERVER_PUBLIC_HOST", "")
if not SERVER_HOST:
    try:
        import urllib.request
        SERVER_HOST = urllib.request.urlopen("https://api.ipify.org", timeout=3).read().decode('utf-8').strip()
    except Exception:
        SERVER_HOST = "127.0.0.1"

SERVER_PORT = os.environ.get("SERVER_PORT") or CONF_PARAMS.get("ListenPort") or "535"
CLIENT_MTU = os.environ.get("CLIENT_MTU", "1280")

HEADER_PROTECTION_KEY = os.environ.get("HEADER_PROTECTION_KEY") or CONF_PARAMS.get("HeaderProtectionKey") or ""
if not HEADER_PROTECTION_KEY:
    HEADER_PROTECTION_KEY = base64.b64encode(secrets.token_bytes(32)).decode('utf-8')

JC = os.environ.get("JC") or CONF_PARAMS.get("Jc", "5")
JMIN = os.environ.get("JMIN") or CONF_PARAMS.get("Jmin", "10")
JMAX = os.environ.get("JMAX") or CONF_PARAMS.get("Jmax", "50")
S1 = os.environ.get("S1") or CONF_PARAMS.get("S1", "12")
S2 = os.environ.get("S2") or CONF_PARAMS.get("S2", "12")
S3 = os.environ.get("S3") or CONF_PARAMS.get("S3", "12")
S4 = os.environ.get("S4") or CONF_PARAMS.get("S4", "12")
H1 = os.environ.get("H1") or CONF_PARAMS.get("H1", "1")
H2 = os.environ.get("H2") or CONF_PARAMS.get("H2", "2")
H3 = os.environ.get("H3") or CONF_PARAMS.get("H3", "3")
H4 = os.environ.get("H4") or CONF_PARAMS.get("H4", "4")
# ponytail: default I1 matches standard DNS init vector; overridable via env or awg0.conf
I1 = os.environ.get("I1") or CONF_PARAMS.get("I1", "<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>")

def ensure_container_networking():
    """Ensure TCPMSS clamping and proper MTU inside the container for mobile stability."""
    run_cmd(f"docker exec {CONTAINER} iptables -t mangle -C FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || docker exec {CONTAINER} iptables -t mangle -A FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true")
    run_cmd(f"docker exec {CONTAINER} iptables -t mangle -C FORWARD -i awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || docker exec {CONTAINER} iptables -t mangle -A FORWARD -i awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true")
    run_cmd(f"docker exec {CONTAINER} ip link set mtu {CLIENT_MTU} dev awg0 2>/dev/null || true")

def get_server_pubkey():
    pub = read_container_file("/opt/amnezia/awg/wireguard_server_public_key.key")
    if pub:
        return pub.strip()
    env_pub = os.environ.get("AWG_SERVER_PUBKEY")
    if env_pub:
        return env_pub
    conf = read_container_file("/opt/amnezia/awg/awg0.conf")
    m = re.search(r"PrivateKey\s*=\s*(\S+)", conf)
    if m:
        priv = m.group(1)
        stdout, _, rc = run_cmd(f"docker exec -i {CONTAINER} awg pubkey 2>/dev/null || echo '{priv}' | wg pubkey 2>/dev/null", input_data=priv)
        if rc == 0 and stdout:
            return stdout
    raise RuntimeError("Server public key not found in container /opt/amnezia/awg/")

def get_server_psk():
    psk = read_container_file("/opt/amnezia/awg/wireguard_psk.key")
    if psk:
        return psk.strip()
    env_psk = os.environ.get("AWG_SERVER_PSK")
    if env_psk:
        return env_psk
    conf = read_container_file("/opt/amnezia/awg/awg0.conf")
    m = re.search(r"PresharedKey\s*=\s*(\S+)", conf)
    if m:
        return m.group(1).strip()
    return base64.b64encode(secrets.token_bytes(32)).decode('utf-8')

def load_clients_table():
    txt = read_container_file("/opt/amnezia/awg/clientsTable")
    if txt:
        try:
            return json.loads(txt)
        except Exception:
            return []
    return []

def save_clients_table(table):
    write_container_file("/opt/amnezia/awg/clientsTable", json.dumps(table, indent=4, ensure_ascii=False))

def encode_amnezia_vpnuri_31(conf_text: str, client_ip: str, client_priv: str, client_pub: str, description: str = "AmneziaWG 3.1") -> str:
    server_pub = get_server_pubkey()
    server_psk = get_server_psk()
    port_int = int(SERVER_PORT)

    internal_config = f"""[Interface]
Address = {client_ip}/32
DNS = $PRIMARY_DNS, $SECONDARY_DNS
PrivateKey = {client_priv}
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
I1 = {I1}
HeaderProtectionKey = {HEADER_PROTECTION_KEY}
RekeyAfterTime = 100-120
RekeyTimeout = 3-7
RejectAfterTime = 150-180
KeepaliveTimeout = 5-15
MaxHandshakeAttempts = 15-20
RandomTrailers = on
DisableCookies = on

[Peer]
PublicKey = {server_pub}
PresharedKey = {server_psk}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = {SERVER_HOST}:{SERVER_PORT}
PersistentKeepalive = 25-35
"""

    last_config_dict = {
        "DisableCookies": "on",
        "H1": H1,
        "H2": H2,
        "H3": H3,
        "H4": H4,
        "HeaderProtectionKey": HEADER_PROTECTION_KEY,
        "I1": I1,
        "Jc": JC,
        "Jmax": JMAX,
        "Jmin": JMIN,
        "KeepaliveTimeout": "5-15",
        "MaxHandshakeAttempts": "15-20",
        "RandomTrailers": "on",
        "RejectAfterTime": "150-180",
        "RekeyAfterTime": "100-120",
        "RekeyTimeout": "3-7",
        "S1": S1,
        "S2": S2,
        "S3": S3,
        "S4": S4,
        "allowed_ips": ["0.0.0.0/0", "::/0"],
        "clientId": client_pub,
        "client_ip": client_ip,
        "client_priv_key": client_priv,
        "client_pub_key": client_pub,
        "config": internal_config,
        "hostName": SERVER_HOST,
        "mtu": str(CLIENT_MTU),
        "persistent_keep_alive": "25-35",
        "port": port_int,
        "psk_key": server_psk,
        "server_pub_key": server_pub
    }

    awg_dict = {
        "DisableCookies": "on",
        "H1": H1,
        "H2": H2,
        "H3": H3,
        "H4": H4,
        "HeaderProtectionKey": HEADER_PROTECTION_KEY,
        "I1": I1,
        "I2": "",
        "I3": "",
        "I4": "",
        "I5": "",
        "Jc": JC,
        "Jmax": JMAX,
        "Jmin": JMIN,
        "KeepaliveTimeout": "5-15",
        "MaxHandshakeAttempts": "15-20",
        "RandomTrailers": "on",
        "RejectAfterTime": "150-180",
        "RekeyAfterTime": "100-120",
        "RekeyTimeout": "3-7",
        "S1": S1,
        "S2": S2,
        "S3": S3,
        "S4": S4,
        "last_config": json.dumps(last_config_dict, ensure_ascii=False),
        "port": str(SERVER_PORT),
        "protocol_version": "3.1",
        "subnet_address": "10.8.0.0",
        "transport_proto": "udp"
    }

    container_data = {
        "containers": [
            {
                "awg": awg_dict,
                "container": CONTAINER
            }
        ],
        "defaultContainer": CONTAINER,
        "description": description,
        "dns1": "76.76.10.0",
        "dns2": "1.1.1.1",
        "format_version": 1,
        "hostName": SERVER_HOST
    }

    json_str = json.dumps(container_data, ensure_ascii=False)
    json_bytes = json_str.encode("utf-8")
    compressed = zlib.compress(json_bytes, 8)
    payload = struct.pack(">I", len(json_bytes)) + compressed
    encoded_b64 = base64.urlsafe_b64encode(payload).decode("utf-8").rstrip("=")
    return f"vpn://{encoded_b64}"

def check_status():
    ensure_container_networking()
    out, _, rc = run_cmd(f"docker inspect -f '{{{{.State.Running}}}}' {CONTAINER}")
    is_running = (rc == 0 and out.strip() == "true")
    if not is_running:
        return {"ok": False, "status": "offline", "active": False, "error": f"Container {CONTAINER} is not running"}

    out, _, rc = run_cmd(f"docker exec {CONTAINER} ip link show awg0")
    if rc != 0:
        return {"ok": False, "status": "offline", "active": False, "error": "Interface awg0 not found in container"}

    table = load_clients_table()
    return {
        "ok": True,
        "status": "online",
        "active": True,
        "service": {"unit": CONTAINER, "active": True},
        "interface": {"name": "awg0", "present": True},
        "port": {"number": int(SERVER_PORT), "proto": "udp", "listening": True},
        "clients": {"total": len(table)}
    }

def get_stats():
    ensure_container_networking()
    dump_out, _, rc = run_cmd(f"docker exec {CONTAINER} awg show awg0 dump")
    if rc != 0:
        return {"ok": False, "error": "Failed to run awg show in container", "clients": [], "items": []}

    table = load_clients_table()
    names_by_pub = {item.get("clientId", "").strip(): item.get("userData", {}).get("clientName", "") for item in table}

    clients = []
    lines = dump_out.strip().splitlines()
    for line in lines[1:]:
        parts = line.strip().split()
        if len(parts) >= 7:
            pubkey = parts[0]
            endpoint = parts[2] if parts[2] != "(none)" else None
            allowed_ips = parts[3]
            handshake = int(parts[4]) if parts[4].isdigit() else 0
            rx = int(parts[5]) if parts[5].isdigit() else 0
            tx = int(parts[6]) if parts[6].isdigit() else 0
            name = names_by_pub.get(pubkey, pubkey)
            ip = allowed_ips.split("/")[0]

            clients.append({
                "name": name,
                "client_name": name,
                "public_key": pubkey,
                "ip": ip,
                "allowed_ips": allowed_ips,
                "latest_handshake": handshake,
                "rx_bytes": rx,
                "tx_bytes": tx,
                "endpoint": endpoint
            })

    return {
        "ok": True,
        "status": "online",
        "clients": clients,
        "items": clients,
        "total": len(clients)
    }

def find_next_ip():
    conf_content = read_container_file("/opt/amnezia/awg/awg0.conf")
    table = load_clients_table()

    # Collect all currently assigned IPs
    used = set()
    for m in re.finditer(r'10\.8\.(\d+)\.(\d+)', conf_content):
        used.add(f"10.8.{m.group(1)}.{m.group(2)}")
    for item in table:
        a_ip = item.get("userData", {}).get("allowed_ips", "")
        m = re.search(r'10\.8\.(\d+)\.(\d+)', a_ip)
        if m:
            used.add(f"10.8.{m.group(1)}.{m.group(2)}")

    # Reserve special / network IPs
    used.add("10.8.0.0")    # network address
    used.add("10.8.0.1")    # gateway
    used.add("10.8.1.0")    # server interface address
    used.add("10.8.3.255")  # broadcast

    # Priority 1: Fill out current 10.8.1.x subnet (.3 to .254)
    for oct4 in range(3, 255):
        candidate = f"10.8.1.{oct4}"
        if candidate not in used:
            return candidate

    # Priority 2: Next subnets in /22 pool (10.8.2.x, 10.8.3.x, 10.8.0.x)
    for oct3 in (2, 3, 0):
        start_oct4 = 2 if oct3 == 0 else 1
        for oct4 in range(start_oct4, 255):
            candidate = f"10.8.{oct3}.{oct4}"
            if candidate not in used:
                return candidate

    raise RuntimeError("No free IPs in 10.8.0.0/22 subnet pool (1000+ peers reached)")

def add_client(client_name):
    if not client_name:
        return {"ok": False, "error": "client_name_required"}

    ensure_container_networking()

    table = load_clients_table()
    for item in table:
        if item.get("userData", {}).get("clientName") == client_name:
            remove_client(client_name)
            break

    client_ip = find_next_ip()
    priv_out, _, _ = run_cmd(f"docker exec {CONTAINER} awg genkey", check=True)
    client_priv = priv_out.strip()
    pub_out, _, _ = run_cmd(f"docker exec -i {CONTAINER} awg pubkey", check=True, input_data=client_priv)
    client_pub = pub_out.strip()
    server_psk = get_server_psk()
    server_pub = get_server_pubkey()

    # 1. Add peer to running container
    run_cmd(
        f"docker exec {CONTAINER} awg set awg0 peer {client_pub} preshared-key /opt/amnezia/awg/wireguard_psk.key allowed-ips {client_ip}/32",
        check=True
    )

    # 2. Append peer to /opt/amnezia/awg/awg0.conf
    peer_block = (
        f"\n# client: {client_name}\n"
        f"[Peer]\n"
        f"PublicKey = {client_pub}\n"
        f"PresharedKey = {server_psk}\n"
        f"AllowedIPs = {client_ip}/32\n"
    )
    append_container_file("/opt/amnezia/awg/awg0.conf", peer_block)

    # 3. Update clientsTable
    table = load_clients_table()
    table.append({
        "clientId": client_pub,
        "userData": {
            "allowed_ips": f"{client_ip}/32",
            "clientName": client_name,
            "creationDate": datetime.now(timezone.utc).strftime("%a %b %d %H:%M:%S %Y")
        }
    })
    save_clients_table(table)

    # 4. Generate client .conf
    conf_content = f"""[Interface]
Address = {client_ip}/32
DNS = 76.76.10.0, 1.1.1.1
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
I1 = {I1}
HeaderProtectionKey = {HEADER_PROTECTION_KEY}
RekeyAfterTime = 100-120
RekeyTimeout = 3-7
RejectAfterTime = 150-180
KeepaliveTimeout = 5-15
MaxHandshakeAttempts = 15-20
RandomTrailers = on
DisableCookies = on

[Peer]
PublicKey = {server_pub}
PresharedKey = {server_psk}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = {SERVER_HOST}:{SERVER_PORT}
PersistentKeepalive = 25-35
"""

    conf_file = AWG_DIR / f"{client_name}.conf"
    conf_file.write_text(conf_content, encoding="utf-8")
    conf_file.chmod(0o600)

    # 5. Generate client .vpnuri
    vpnuri = encode_amnezia_vpnuri_31(
        conf_content, client_ip, client_priv, client_pub,
        description=f"AmneziaWG - {client_name}"
    )
    vpnuri_file = AWG_DIR / f"{client_name}.vpnuri"
    vpnuri_file.write_text(vpnuri, encoding="utf-8")
    vpnuri_file.chmod(0o600)

    return {
        "ok": True,
        "status": "added",
        "client": client_name,
        "ip": client_ip,
        "public_key": client_pub
    }

def remove_client(client_name):
    if not client_name:
        return {"ok": False, "error": "client_name_required"}

    table = load_clients_table()
    pubkey = None
    new_table = []
    for item in table:
        c_name = item.get("userData", {}).get("clientName")
        c_id = item.get("clientId")
        if c_name == client_name or c_id == client_name:
            pubkey = c_id
        else:
            new_table.append(item)

    save_clients_table(new_table)

    conf_text = read_container_file("/opt/amnezia/awg/awg0.conf")
    if not pubkey and conf_text:
        m = re.search(r'# client:\s*' + re.escape(client_name) + r'\s*\n\[Peer\]\s*\nPublicKey\s*=\s*([^\s\n]+)', conf_text)
        if m:
            pubkey = m.group(1).strip()
        elif len(client_name) == 44 and "=" in client_name:
            pubkey = client_name

    if pubkey:
        run_cmd(f"docker exec {CONTAINER} awg set awg0 peer {pubkey} remove 2>/dev/null || true")

        if conf_text:
            pattern = r'(?m)(?:# client:[^\n]*\n)?\[Peer\]\s*\nPublicKey\s*=\s*' + re.escape(pubkey) + r'[\s\S]*?(?=\n(?:# client:|\[Peer\]|$))'
            content = re.sub(pattern, '', conf_text).strip() + "\n"
            write_container_file("/opt/amnezia/awg/awg0.conf", content)

    for ext in (".conf", ".vpnuri", ".png", ".vpnuri.png"):
        f = AWG_DIR / f"{client_name}{ext}"
        if f.exists():
            try:
                f.unlink()
            except Exception:
                pass

    return {"ok": True, "status": "removed", "client": client_name}

def block_client(client_name):
    table = load_clients_table()
    pubkey = None
    for item in table:
        if item.get("userData", {}).get("clientName") == client_name:
            pubkey = item.get("clientId")
            break
    conf_text = read_container_file("/opt/amnezia/awg/awg0.conf")
    if not pubkey and conf_text:
        m = re.search(r'# client:\s*' + re.escape(client_name) + r'\s*\n\[Peer\]\s*\nPublicKey\s*=\s*([^\s\n]+)', conf_text)
        if m:
            pubkey = m.group(1).strip()
    if pubkey:
        run_cmd(f"docker exec {CONTAINER} awg set awg0 peer {pubkey} remove 2>/dev/null || true")
    return {"ok": True, "status": "suspended", "client": client_name}

def unblock_client(client_name):
    table = load_clients_table()
    pubkey = None
    ip = None
    for item in table:
        if item.get("userData", {}).get("clientName") == client_name:
            pubkey = item.get("clientId")
            ip = item.get("userData", {}).get("allowed_ips")
            break
    conf_text = read_container_file("/opt/amnezia/awg/awg0.conf")
    if not pubkey and conf_text:
        m = re.search(r'# client:\s*' + re.escape(client_name) + r'\s*\n\[Peer\]\s*\nPublicKey\s*=\s*([^\s\n]+)[\s\S]*?AllowedIPs\s*=\s*([^\s\n]+)', conf_text)
        if m:
            pubkey = m.group(1).strip()
            ip = m.group(2).strip()

    if pubkey and ip:
        run_cmd(f"docker exec {CONTAINER} awg set awg0 peer {pubkey} preshared-key /opt/amnezia/awg/wireguard_psk.key allowed-ips {ip}", check=True)
    return {"ok": True, "status": "unsuspended", "client": client_name}

def main():
    args = sys.argv[1:]
    if not args:
        print(json.dumps(check_status()))
        return

    action = args[0]
    client_name = args[1] if len(args) > 1 and not args[1].startswith("-") else None

    for arg in args[1:]:
        if not arg.startswith("-") and not client_name:
            client_name = arg

    if action in ("status", "check", "info"):
        res = check_status()
    elif action in ("stats", "get-clients", "show"):
        res = get_stats()
    elif action == "add":
        res = add_client(client_name)
    elif action in ("remove", "del", "delete"):
        res = remove_client(client_name)
    elif action in ("block", "suspend", "disable"):
        res = block_client(client_name)
    elif action in ("unblock", "unsuspend", "enable"):
        res = unblock_client(client_name)
    elif action == "restart":
        run_cmd(f"docker restart {CONTAINER}")
        res = {"ok": True, "status": "restarted"}
    elif action == "repair":
        run_cmd(f"docker start {CONTAINER} 2>/dev/null || true")
        res = check_status()
    elif action in ("purge-expired", "set-preset", "preset"):
        res = {"ok": True, "status": "ok"}
    else:
        res = get_stats()

    print(json.dumps(res))

if __name__ == "__main__":
    main()
