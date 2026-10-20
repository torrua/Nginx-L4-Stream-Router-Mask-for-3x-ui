#!/usr/bin/env python3
"""Compatibility entrypoint; use manage_clients.py."""
import runpy
import importlib.util
import sys
from pathlib import Path

target = Path(__file__).with_name("manage_clients.py")
if __name__ == "__main__":
    runpy.run_path(str(target), run_name="__main__")
else:
    spec = importlib.util.spec_from_file_location(__name__, target)
    module = importlib.util.module_from_spec(spec)
    sys.modules[__name__] = module
    spec.loader.exec_module(module)
