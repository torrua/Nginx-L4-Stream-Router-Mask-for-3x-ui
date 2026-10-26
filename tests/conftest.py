"""Pytest configuration and session-wide fixtures."""
import os
import tempfile
import pytest

# Ensure every test runner process has an isolated default lock path
_worker_lock_dir = tempfile.mkdtemp(prefix="vpn_stack_lock_")
os.environ.setdefault("VPN_STACK_LOCK_FILE", os.path.join(_worker_lock_dir, "vpn-stack.lock").replace("\\", "/"))
