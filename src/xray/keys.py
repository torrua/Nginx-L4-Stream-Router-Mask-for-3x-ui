import base64
import os
import re
import secrets
import subprocess
import uuid

# Curve25519 helper (RFC 7748) via common crypto engine
try:
    from src.common.crypto_engine import (
        P, A24, clamp, x25519, curve25519_pubkey, curve25519_reality_pubkey,
        generate_reality_keypair, generate_wg_keypair, generate_dnstt_keypair,
        dnstt_pubkey_from_privkey, validate_dnstt_pubkey
    )
except ImportError:
    try:
        from common.crypto_engine import (
            P, A24, clamp, x25519, curve25519_pubkey, curve25519_reality_pubkey,
            generate_reality_keypair, generate_wg_keypair, generate_dnstt_keypair,
            dnstt_pubkey_from_privkey, validate_dnstt_pubkey
        )
    except ImportError:
        try:
            from crypto_engine import (
                P, A24, clamp, x25519, curve25519_pubkey, curve25519_reality_pubkey,
                generate_reality_keypair, generate_wg_keypair, generate_dnstt_keypair,
                dnstt_pubkey_from_privkey, validate_dnstt_pubkey
            )
        except ImportError:
            try:
                import sys
                from pathlib import Path
                _p = (Path(__file__).resolve().parent.parent / "common").as_posix()
                if _p not in sys.path:
                    sys.path.insert(0, _p)
                from crypto_engine import (
                    P, A24, clamp, x25519, curve25519_pubkey, curve25519_reality_pubkey,
                    generate_reality_keypair, generate_wg_keypair, generate_dnstt_keypair,
                    dnstt_pubkey_from_privkey, validate_dnstt_pubkey
                )
            except Exception:
                pass
# @include "common/crypto_engine.py"

def generate_vlessenc_keypair():
    for candidate in ["/usr/local/x-ui/bin/xray-linux-amd64", "/usr/local/x-ui/bin/xray-linux-arm64", "/usr/local/x-ui/bin/xray", "xray"]:
        try:
            res = subprocess.run([candidate, "vlessenc"], capture_output=True, text=True, timeout=5)
            if res.returncode == 0:
                out = res.stdout
                de_m = re.search(r'"decryption":\s*"([^"]+)"', out)
                en_m = re.search(r'"encryption":\s*"([^"]+)"', out)
                if de_m and en_m:
                    return de_m.group(1), en_m.group(1)
        except Exception:
            pass
    return None, None

def generate_ss2022_key(method="2022-blake3-aes-256-gcm"):
    raw_len = 16 if "128" in method else 32
    return base64.b64encode(os.urandom(raw_len)).decode()

def validate_ss2022_key(key_b64, method="2022-blake3-aes-256-gcm"):
    try:
        if not isinstance(key_b64, str) or not key_b64.strip():
            return False
        k = key_b64.strip().replace('-', '+').replace('_', '/')
        padding = "=" * ((4 - len(k) % 4) % 4)
        raw = base64.b64decode(k + padding, validate=True)
        expected_len = 16 if "128" in method else 32
        return len(raw) == expected_len
    except Exception:
        return False

def generate_mtproto_secret(fake_tls_domain="gateway.icloud.com"):
    domain = fake_tls_domain.strip().lower() if fake_tls_domain else "gateway.icloud.com"
    token = secrets.token_hex(16)
    domain_hex = domain.encode("utf-8").hex()
    return f"ee{token}{domain_hex}"

def validate_mtproto_secret(secret_hex):
    if not isinstance(secret_hex, str):
        return False
    s = secret_hex.strip().lower()
    return s.startswith("ee") and len(s) >= 38 and all(c in "0123456789abcdef" for c in s[2:])

def validate_mtproto_adtag(adtag):
    return bool(isinstance(adtag, str) and re.match(r"^[0-9a-fA-F]{32}$", adtag.strip()))

def generate_shadowtls_password():
    return secrets.token_urlsafe(16)

def validate_shadowtls_password(pw):
    return bool(isinstance(pw, str) and len(pw.strip()) >= 8)

def generate_masque_credentials(default_user="client"):
    return default_user, secrets.token_urlsafe(16)

def generate_naiveproxy_credentials(default_user="user"):
    return default_user, secrets.token_urlsafe(16)

def generate_tuic_credentials(default_uuid=None):
    return default_uuid or str(uuid.uuid4()), secrets.token_urlsafe(16)

