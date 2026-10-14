#!/usr/bin/env bash
PYTHON_BIN="$(which python3 2>/dev/null || echo /usr/bin/python3)"
exec "$PYTHON_BIN" /root/awg/manage_amneziawg.py "$@"