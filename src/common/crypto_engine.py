"""
src/common/crypto_engine.py - Unified RFC 7748 X25519 / Curve25519 Cryptographic Engine.

Single Source of Truth for Curve25519 key exchange, clamping, public key derivation,
and keypair generation across AmneziaWG, Reality, DNSTT, and 3X-UI panel reconciliation.
"""

import base64
import os
from typing import Optional, Tuple

P = 2**255 - 19
A24 = 121665


def clamp(k_bytes):
    """Apply RFC 7748 clamping to 32 private key bytes."""
    if len(k_bytes) != 32:
        raise ValueError(f"Expected 32 private key bytes, got {len(k_bytes)}")
    b = bytearray(k_bytes)
    b[0] &= 248
    b[31] &= 127
    b[31] |= 64
    return int.from_bytes(b, "little")


def x25519(k: int, u: int = 9) -> int:
    """RFC 7748 scalar multiplication on Curve25519 using Montgomery ladder."""
    x1 = u
    x2, z2 = 1, 0
    x3, z3 = u, 1
    for i in range(254, -1, -1):
        bit = (k >> i) & 1
        if bit:
            x2, x3 = x3, x2
            z2, z3 = z3, z2
        A = (x2 + z2) % P
        AA = (A * A) % P
        B = (x2 - z2) % P
        BB = (B * B) % P
        E = (AA - BB) % P
        C = (x3 + z3) % P
        D = (x3 - z3) % P
        DA = (D * A) % P
        CB = (C * B) % P
        x3 = pow(DA + CB, 2, P)
        z3 = (x1 * pow(DA - CB, 2, P)) % P
        x2 = (AA * BB) % P
        z2 = (E * (AA + A24 * E)) % P
        if bit:
            x2, x3 = x3, x2
            z2, z3 = z3, z2
    return (x2 * pow(z2, P - 2, P)) % P


def curve25519_pubkey(priv_b64: str) -> Optional[str]:
    """Derive standard Base64 Curve25519 public key (AmneziaWG / WireGuard format)."""
    try:
        raw_priv = base64.b64decode(priv_b64)
        if len(raw_priv) != 32:
            return None
        k = clamp(raw_priv)
        pub_raw = x25519(k, 9).to_bytes(32, "little")
        return base64.b64encode(pub_raw).decode()
    except Exception:
        return None


def curve25519_reality_pubkey(priv_b64url: str) -> Optional[str]:
    """Derive unpadded URL-safe Base64 Curve25519 public key (Reality format)."""
    try:
        padding = "=" * ((4 - len(priv_b64url) % 4) % 4)
        raw_priv = base64.urlsafe_b64decode(priv_b64url + padding)
        if len(raw_priv) != 32:
            return None
        k = clamp(raw_priv)
        pub_raw = x25519(k, 9).to_bytes(32, "little")
        return base64.urlsafe_b64encode(pub_raw).decode().rstrip("=")
    except Exception:
        return None


def generate_reality_keypair() -> Tuple[str, str]:
    """Generate a random (private_key, public_key) pair in Reality URL-safe Base64 format."""
    priv_raw = os.urandom(32)
    k = clamp(priv_raw)
    pub_raw = x25519(k, 9).to_bytes(32, "little")
    priv_b64 = base64.urlsafe_b64encode(priv_raw).decode().rstrip("=")
    pub_b64 = base64.urlsafe_b64encode(pub_raw).decode().rstrip("=")
    return priv_b64, pub_b64


def generate_wg_keypair() -> Tuple[str, str]:
    """Generate a random (private_key, public_key) pair in standard WireGuard / AWG Base64 format."""
    priv_raw = os.urandom(32)
    k = clamp(priv_raw)
    pub_raw = x25519(k, 9).to_bytes(32, "little")
    priv_b64 = base64.b64encode(priv_raw).decode()
    pub_b64 = base64.b64encode(pub_raw).decode()
    return priv_b64, pub_b64


def generate_dnstt_keypair() -> Tuple[str, str]:
    """Generate a random (private_key_hex, public_key_hex) pair for DNSTT tunnels."""
    raw_priv = os.urandom(32)
    k = clamp(raw_priv)
    pub_hex = ((x25519(k, 9)) % P).to_bytes(32, "little").hex()
    return raw_priv.hex(), pub_hex


def dnstt_pubkey_from_privkey(priv_hex: str) -> Optional[str]:
    """Derive DNSTT public key (hex) from private key (hex)."""
    try:
        raw_priv = bytes.fromhex(priv_hex.strip())
        if len(raw_priv) != 32:
            return None
        k = clamp(raw_priv)
        return ((x25519(k, 9)) % P).to_bytes(32, "little").hex()
    except Exception:
        return None


def validate_dnstt_pubkey(pubkey: str) -> bool:
    """Validate 64-char hex string as DNSTT public key."""
    if not isinstance(pubkey, str):
        return False
    s = pubkey.strip().lower()
    return len(s) == 64 and all(c in "0123456789abcdef" for c in s)


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        cmd = sys.argv[1]
        if cmd == "wg_pubkey" and len(sys.argv) > 2:
            print(curve25519_pubkey(sys.argv[2]) or "")
        elif cmd == "wg_keypair":
            priv, pub = generate_wg_keypair()
            print(f"{priv} {pub}")
        elif cmd == "reality_pubkey" and len(sys.argv) > 2:
            print(curve25519_reality_pubkey(sys.argv[2]) or "")
        elif cmd == "reality_keypair":
            priv, pub = generate_reality_keypair()
            print(f"{priv} {pub}")
        elif cmd == "dnstt_keypair":
            priv, pub = generate_dnstt_keypair()
            if len(sys.argv) > 3:
                with open(sys.argv[2], "w", encoding="utf-8") as kf:
                    kf.write(priv + "\n")
                with open(sys.argv[3], "w", encoding="utf-8") as pf:
                    pf.write(pub + "\n")
            else:
                print(f"{priv} {pub}")
        elif cmd == "dnstt_pubkey" and len(sys.argv) > 2:
            print(dnstt_pubkey_from_privkey(sys.argv[2]) or "")
