"""Path resolution shared by the standalone configuration and repair tools."""
import secrets
import shlex
from pathlib import Path


def resolve_panel_path(configured, existing):
    """Preserve explicit and existing paths, including root '/' and legacy installation paths."""
    if configured is not None and configured.strip() in ("/", "root", "none", "off"):
        return ""
    if configured and configured.strip():
        return configured.strip().strip("/")
    if existing is not None and existing.strip() == "/":
        return ""
    if existing and existing.strip().strip("/"):
        return existing.strip().strip("/")
    return "panel-" + secrets.token_hex(16)


def resolve_wstunnel_prefix(configured, service_file="/etc/systemd/system/wstunnel.service"):
    """Read the applied prefix; reporting must never create a new server secret."""
    try:
        for line in Path(service_file).read_text(encoding="utf-8").splitlines():
            if not line.strip().startswith("ExecStart="):
                continue
            args = shlex.split(line.strip().split("=", 1)[1])
            for index, arg in enumerate(args):
                if arg == "--restrict-http-upgrade-path-prefix" and index + 1 < len(args):
                    return args[index + 1].strip("/")
                if arg.startswith("--restrict-http-upgrade-path-prefix="):
                    return arg.split("=", 1)[1].strip("/")
    except (OSError, ValueError):
        pass
    return (configured or "").strip().strip("/")
