#!/usr/bin/env bash
# Compatibility launcher. Use configure-panel.sh.
set -euo pipefail
COMPAT_TARGET="configure-panel.sh"
# Transitional entrypoint. Prefer the canonical script next to this file.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
if [ -f "$script_dir/$COMPAT_TARGET" ]; then
    exec bash "$script_dir/$COMPAT_TARGET" "$@"
fi

# Old raw download URLs continue to work when only the launcher was downloaded.
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/server-script.XXXXXX")
temporary_script="$temporary_dir/$COMPAT_TARGET"
trap 'rm -f -- "$temporary_script"; rmdir -- "$temporary_dir"' EXIT
url="https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/$COMPAT_TARGET"
if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$temporary_script"
elif command -v wget >/dev/null 2>&1; then
    wget -qO "$temporary_script" "$url"
else
    printf 'Download %s next to this script, or install curl/wget.\n' "$COMPAT_TARGET" >&2
    exit 1
fi
status=0
bash "$temporary_script" "$@" || status=$?
exit "$status"
