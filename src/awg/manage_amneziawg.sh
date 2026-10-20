#!/usr/bin/env bash
# Compatibility launcher. Use manage-clients.sh.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$script_dir/manage-clients.sh" "$@"
