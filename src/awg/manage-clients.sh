#!/bin/sh
# ==============================================================================
# manage-clients.sh — Universal AmneziaWG CLI Launcher
# ==============================================================================
set -eu

AWG_DIR="${AWG_DIR:-/root/awg}"
PYTHON_BIN="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"

# Direct execution if awg-mgr is a compiled binary
if [ -x "$AWG_DIR/awg-mgr" ] && [ ! -L "$AWG_DIR/awg-mgr" ]; then
    exec "$AWG_DIR/awg-mgr" "$@"
fi

if [ ! -f "$AWG_DIR/manage_clients.py" ]; then
    script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "/root/awg")"
    if [ -f "$script_dir/manage_clients.py" ]; then
        exec "$PYTHON_BIN" "$script_dir/manage_clients.py" "$@"
    fi
    echo "ERROR: manage_clients.py not found in $AWG_DIR" >&2
    exit 1
fi

exec "$PYTHON_BIN" "$AWG_DIR/manage_clients.py" "$@"
