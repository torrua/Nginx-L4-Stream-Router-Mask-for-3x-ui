"""Local node-token lifecycle for the 3X-UI API-token SQLite schema."""
from contextlib import closing
import hashlib
import hmac
import os
from pathlib import Path
import secrets
import sqlite3
import sys
import tempfile
import time


def connect(path):
    return sqlite3.connect(Path(path).resolve().as_uri() + "?mode=rw", uri=True, timeout=10)


def verify(path, name, token, required_scope=None):
    if not token:
        return False
    try:
        with closing(connect(path)) as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute("SELECT * FROM api_tokens WHERE name=?", (name,)).fetchone()
        if row is None or not row["enabled"]:
            return False
        if "expires_at" in row.keys():
            expiry = int(row["expires_at"] or 0)
            if expiry > 100_000_000_000:
                expiry //= 1000
            if expiry and expiry <= int(time.time()):
                return False
        if "scope" in row.keys():
            if row["scope"] not in ("admin", "node-admin", "node-sync"):
                return False
            if required_scope and row["scope"] != required_scope:
                return False
        return hmac.compare_digest(hashlib.sha256(token.encode()).hexdigest(), row["token"])
    except (sqlite3.Error, ValueError, TypeError):
        return False


def create(path, name, scope="node-sync"):
    with closing(connect(path)) as conn, conn:
        columns = {row[1] for row in conn.execute("PRAGMA table_info(api_tokens)")}
        if not {"name", "token", "enabled"} <= columns:
            raise ValueError("Unsupported 3X-UI API-token schema")
        token = secrets.token_hex(32)
        values = {"name": name, "token": hashlib.sha256(token.encode()).hexdigest(), "enabled": 1}
        target_scope = scope if scope else "node-sync"
        scope_map = {
            "node-sync": ("scope", "node-sync"),
            "node-admin": ("scope", "node-admin"),
            "admin": ("scope", "admin"),
        }
        scope_entry = scope_map.get(target_scope, ("scope", target_scope))
        for column, value in (scope_entry, ("created_at", int(time.time())), ("expires_at", 0)):
            if column in columns:
                values[column] = value
        if conn.execute("SELECT 1 FROM api_tokens WHERE name=?", (name,)).fetchone():
            update = {key: value for key, value in values.items() if key != "name"}
            conn.execute("UPDATE api_tokens SET " + ",".join(key + "=?" for key in update) + " WHERE name=?",
                         [*update.values(), name])
        else:
            conn.execute("INSERT INTO api_tokens (" + ",".join(values) + ") VALUES ("
                         + ",".join("?" for _ in values) + ")", list(values.values()))
    return token


def atomic_write(path, text):
    path = Path(path)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def persist(runtime_path, config_path, name, token, scope=None):
    values = {"ENABLE_NODE_TOKEN": "y", "NODE_TOKEN_NAME": name, "NODE_TOKEN": token}
    if scope:
        values["NODE_TOKEN_SCOPE"] = scope
    if any("\n" in value or "\r" in value for value in values.values()):
        raise ValueError("Node-token values must be single-line strings")
    # These files are read as literal KEY=value data, never evaluated as shell code.
    lines = [f'{key}="{value}"' for key, value in values.items()]
    atomic_write(runtime_path, "\n".join(lines) + "\n")
    if config_path and Path(config_path).is_file():
        previous = Path(config_path).read_text(encoding="utf-8").splitlines()
        previous = [line for line in previous if line.partition("=")[0] not in values]
        atomic_write(config_path, "\n".join([*previous, *lines]) + "\n")


def main(args):
    action, *values = args
    if action == "verify":
        return 0 if verify(*values) else 1
    if action == "create":
        print(create(*values))
    elif action == "persist":
        persist(*values)
    else:
        raise ValueError("Unknown node-token operation")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, ValueError, sqlite3.Error) as error:
        print(f"Node API token: {error}", file=sys.stderr)
        raise SystemExit(1)
