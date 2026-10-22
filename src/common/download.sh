#!/usr/bin/env bash
# ==============================================================================
# src/common/download.sh - Verifiable Component Downloader (T04, T05)
# ==============================================================================
# Enforces timeouts, retry limits, temporary staging, and cryptographic SHA256
# verification against components-manifest.json before any binary is installed.
# ==============================================================================

DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-15}"
DOWNLOAD_MAX_RETRIES="${DOWNLOAD_MAX_RETRIES:-3}"
MANIFEST_FILE="${MANIFEST_FILE:-${ROOT_DIR:-.}/components-manifest.json}"

verify_file_sha256() {
    local file="$1"
    local expected_hash="$2"

    [ -f "$file" ] || return 1
    [ -n "$expected_hash" ] || return 1

    local actual_hash=""
    if command -v sha256sum >/dev/null 2>&1; then
        actual_hash=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual_hash=$(shasum -a 256 "$file" | awk '{print $1}')
    elif command -v openssl >/dev/null 2>&1; then
        actual_hash=$(openssl dgst -sha256 "$file" | awk '{print $NF}')
    else
        actual_hash=$(python3 -c "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())" "$file" 2>/dev/null || echo "")
    fi

    [ -n "$actual_hash" ] && [ "${actual_hash,,}" = "${expected_hash,,}" ]
}

download_verified_file() {
    local url="$1"
    local dest_file="$2"
    local expected_hash="${3:-}"
    local max_size_bytes="${4:-104857600}" # Default 100MB limit

    local staging_tmp
    staging_tmp=$(mktemp "/tmp/dl-staging.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/dl-staging.XXXXXX") || return 1

    local urls=("$url")
    if [[ "$url" =~ ^https://github\.com/ ]]; then
        urls+=("https://ghfast.top/$url")
    fi

    local success=0
    for candidate_url in "${urls[@]}"; do
        local attempt=1
        while [ "$attempt" -le "$DOWNLOAD_MAX_RETRIES" ]; do
            if curl -fsSL --connect-timeout "$DOWNLOAD_TIMEOUT" --max-time 120 "$candidate_url" -o "$staging_tmp" 2>/dev/null; then
                # Size limit validation (T05.C04)
                local file_size=0
                file_size=$(wc -c < "$staging_tmp" 2>/dev/null || stat -c%s "$staging_tmp" 2>/dev/null || echo 0)
                if [ "$file_size" -gt "$max_size_bytes" ] || [ "$file_size" -eq 0 ]; then
                    rm -f "$staging_tmp"
                    return 2
                fi

                # Checksum validation (T05.C02, T05.C03)
                if [ -n "$expected_hash" ]; then
                    if ! verify_file_sha256 "$staging_tmp" "$expected_hash"; then
                        rm -f "$staging_tmp"
                        return 3
                    fi
                fi

                success=1
                break 2
            fi
            attempt=$((attempt + 1))
            sleep 1
        done
    done

    if [ "$success" -eq 1 ]; then
        mkdir -p "$(dirname "$dest_file")" 2>/dev/null || true
        mv -f "$staging_tmp" "$dest_file"
        return 0
    else
        rm -f "$staging_tmp" 2>/dev/null || true
        return 1
    fi
}

get_manifest_python() {
    if [ -n "${PYTHON_CMD:-}" ] && "$PYTHON_CMD" -c "import json, sys" 2>/dev/null; then
        echo "$PYTHON_CMD"
        return 0
    fi
    if python3 -c "import json, sys" 2>/dev/null; then
        echo "python3"
        return 0
    fi
    if python -c "import json, sys" 2>/dev/null; then
        echo "python"
        return 0
    fi
    return 1
}

get_manifest_component_data() {
    local comp_name="$1"
    local arch="${2:-x86_64}"
    local py_cmd
    py_cmd=$(get_manifest_python || echo "")

    [ -n "$py_cmd" ] || return 1

    "$py_cmd" -c "
import json, sys, os

FALLBACK = {
    'shadow-tls': {
        'x86_64': ('https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-x86_64-unknown-linux-musl', 'a173f5f2d57f45211b68e10ceeddc15b1791077b914fa89747bc705fddc71532', 15728640, '0.2.25'),
        'aarch64': ('https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-aarch64-unknown-linux-musl', '3295476b37f549a68906519d3eaecb74bf3b6eaf9094cebb16ee84f0151373c6', 15728640, '0.2.25')
    },
    'wstunnel': {
        'x86_64': ('https://github.com/erebe/wstunnel/releases/download/v10.1.7/wstunnel_10.1.7_linux_amd64.tar.gz', '79c5beda18655d8ededd507995d9aebd524c35ddc7abfd0aa733b98b3fb895a4', 26214400, '10.1.7'),
        'aarch64': ('https://github.com/erebe/wstunnel/releases/download/v10.1.7/wstunnel_10.1.7_linux_arm64.tar.gz', '0839c8ba6c812b60d8b3f57176a3c52268f1438daa814f985d492db6c5b41c8a', 26214400, '10.1.7')
    },
    'sing-box': {
        'x86_64': ('https://github.com/SagerNet/sing-box/releases/download/v1.11.4/sing-box-1.11.4-linux-amd64.tar.gz', '0bb762ef286b36c2016d9107fc1f089be7a75f6d579b33f067d31e696c05927e', 52428800, '1.11.4'),
        'aarch64': ('https://github.com/SagerNet/sing-box/releases/download/v1.11.4/sing-box-1.11.4-linux-arm64.tar.gz', '4e687359db42b6a28ef93f9cd2cb9549c4b0079cc7e49bc5f6ecbf98257a2507', 52428800, '1.11.4')
    },
    'zapret': {
        'all': ('https://github.com/bol-van/zapret/releases/download/v70/zapret-v70.tar.gz', '142c38a0aa17839fa33c675a740d80aff9302817a71f11212274fbedf9f03015', 20971520, '70')
    },
    'AdGuardHome': {
        'x86_64': ('https://github.com/AdguardTeam/AdGuardHome/releases/download/v0.107.56/AdGuardHome_linux_amd64.tar.gz', '044a8fa378de2ee90c9f290efba18d67dddba650c239c577dc138795e40b5832', 41943040, '0.107.56'),
        'aarch64': ('https://github.com/AdguardTeam/AdGuardHome/releases/download/v0.107.56/AdGuardHome_linux_arm64.tar.gz', '2718ad45db96769e2e24272847b140dbaa6b0c873af02cec14ebe27a1c434712', 41943040, '0.107.56')
    },
    'acme.sh': {
        'all': ('https://github.com/acmesh-official/acme.sh/archive/refs/tags/3.0.8.tar.gz', '51f4f9580e91b038a7dd0207631bf9b1be0aab6a0094d0a3cbb4b21cd86f71df', 2097152, '3.0.8')
    }
}

comp_name = sys.argv[1]
arch = sys.argv[2]
arch_aliases = {'amd64': 'x86_64', 'arm64': 'aarch64'}
arch = arch_aliases.get(arch, arch)
manifest_p = os.environ.get('MANIFEST_FILE', '')

if not manifest_p or not os.path.isfile(manifest_p):
    for candidate in [
        'components-manifest.json',
        os.path.join(os.environ.get('ROOT_DIR', '.'), 'components-manifest.json'),
        '/usr/local/share/vpn-stack/components-manifest.json',
    ]:
        if os.path.isfile(candidate):
            manifest_p = candidate
            break

data = None
if manifest_p and os.path.isfile(manifest_p):
    try:
        with open(manifest_p, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except Exception:
        data = None

if data and 'components' in data and comp_name in data['components']:
    comp = data['components'][comp_name]
    artifacts = comp.get('artifacts', {})
    art = artifacts.get(arch) or artifacts.get('all')
    if art:
        url = art.get('url', '')
        sha256 = art.get('sha256', '')
        max_sz = comp.get('max_size_bytes', 104857600)
        version = comp.get('version', '')
        print(f'{url}|{sha256}|{max_sz}|{version}')
        sys.exit(0)

# Fallback to embedded pinned metadata
if comp_name in FALLBACK:
    comp_map = FALLBACK[comp_name]
    art = comp_map.get(arch) or comp_map.get('all')
    if art:
        url, sha256, max_sz, version = art
        print(f'{url}|{sha256}|{max_sz}|{version}')
        sys.exit(0)

sys.exit(1)
" "$comp_name" "$arch" 2>/dev/null
}

download_manifest_component() {
    local comp_name="$1"
    local dest_file="$2"
    local cur_arch="${3:-}"

    if [ -z "$cur_arch" ]; then
        cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    fi
    case "$cur_arch" in
        x86_64|amd64) cur_arch="x86_64" ;;
        aarch64|arm64) cur_arch="aarch64" ;;
        all) cur_arch="all" ;;
        *) cur_arch="x86_64" ;;
    esac

    local comp_meta
    comp_meta=$(get_manifest_component_data "$comp_name" "$cur_arch")

    if [ -n "$comp_meta" ]; then
        local url sha256 max_size version
        IFS='|' read -r url sha256 max_size version <<< "$comp_meta"
        if [ -n "$url" ] && [ -n "$sha256" ]; then
            download_verified_file "$url" "$dest_file" "$sha256" "$max_size"
            return $?
        fi
    fi
    return 1
}

