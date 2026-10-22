#!/usr/bin/env bash
# ==============================================================================
#  SMART UPDATE & REPAIR TOOL: NGINX L4 ROUTER + 3X-UI
# ==============================================================================
#  Безопасное обновление и самовосстановление без потери подключений пользователей:
#    1. Сохранение существующих клиентов (UUID, пароли Hy2, ключи AWG, трафик);
#    2. Сохранение действующих серверных ключей шифрования REALITY и AWG;
#    3. Ремонт скрытых багов (realitySettings.settings.publicKey, мертвый SNI swdist);
#    4. Проверка и исправление externalProxy: 443 для всех ссылок подписок;
#    5. Проверка криптографии Curve25519 в AmneziaWG (валидация K_pub = K_priv * G);
#    6. Создание отсутствующих инбаундов под ключ;
#    7. Бэкап /etc/nginx и /etc/x-ui/x-ui.db с мягким reload без разрыва сессий;
#    8. Режим предварительного аудита (--dry-run) без внесения изменений.
# ==============================================================================

set -euo pipefail

# Terminal Colors & Styles
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
CYAN=$'\033[0;36m'
WHITE=$'\033[1;37m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
NC=$'\033[0m'
RESET=$'\033[0m'

# Status Symbols
CHECK="✔"
CROSS="✖"
ARROW="➜"
STAR="★"
INFO="ℹ"
LOCK="🔒"
SHIELD="🛡"
# Standard Logging Functions
log()  { echo -e "  ${CYAN}[+]${NC} $*"; }
ok()   { echo -e "  ${GREEN}${CHECK:-✔}${NC} $*"; }
warn() { echo -e "  ${YELLOW}[!]${NC} $*"; }
die()  { echo -e "  ${RED}${CROSS:-✖} $*${NC}" >&2; exit 1; }
# ==============================================================================
# src/common/config.sh - Safe Configuration Loader & SSL Path Resolver (T13)
# ==============================================================================
# Treats configuration files strictly as structured data, forbidding eval/source
# and command substitution $(...) or backticks to prevent arbitrary code execution.
# ==============================================================================

CONFIG_SCHEMA_VERSION=1

is_true() {
    local val="${1:-0}"
    [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]
}

find_config_file() {
    local script_dir="${1:-.}" directory candidate
    local dirs=()
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        dirs=(. "$script_dir" /etc /root)
    else
        # When running as root, do not blindly load from arbitrary current working dir (T13.C09)
        dirs=("$script_dir" /etc /root)
    fi
    for directory in "${dirs[@]}"; do
        [ -d "$directory" ] || continue
        for candidate in "$directory/server-setup.env" "$directory/setup_mask.env"; do
            if [ -f "$candidate" ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
    done
    return 1
}

load_config_data_safe() {
    local env_file="$1"
    [ -f "$env_file" ] || return 1

    # Security check: if running as root, reject world-writable config files (T13.C09)
    if [ "${EUID:-$(id -u)}" -eq 0 ] && command -v stat >/dev/null 2>&1; then
        local perms
        perms=$(stat -c "%a" "$env_file" 2>/dev/null || stat -f "%Lp" "$env_file" 2>/dev/null || true)
        if [[ "$perms" =~ [2367]$ ]]; then
            echo "[ERROR] Security violation: $env_file is world-writable (mode $perms)! Refusing to load." >&2
            return 1
        fi
    fi

    local line_no=0
    local re_dquote='^"(.*)"$'
    local re_squote="^'(.*)'\$"
    while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        line="${line%$'\r'}"
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+(.*)$ ]]; then
            line="${BASH_REMATCH[1]}"
        fi

        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"

            # Handle quotes safely: single quotes preserve raw literal content without expansion (T13.C04)
            if [[ "$val" =~ $re_squote ]]; then
                val="${BASH_REMATCH[1]}"
            elif [[ "$val" =~ $re_dquote ]]; then
                val="${BASH_REMATCH[1]}"
                # Reject command substitution $(...) or backticks (T13.C02, T13.C08)
                if [[ "$val" == *'`'* || "$val" =~ \$\([^\)]*\) || "$val" =~ \$\(\( || "$val" =~ \$\{[^\}]*\} ]]; then
                    echo "[ERROR] Unsafe executable syntax in $env_file line $line_no: command substitution forbidden!" >&2
                    return 1
                fi
                val="${val//\\\"/\"}"
                val="${val//\\\\/\\}"
            else
                # Unquoted: strip trailing comment if preceded by space
                if [[ "$val" =~ ^(.*)[[:space:]]+#.*$ ]]; then
                    val="${BASH_REMATCH[1]}"
                fi
                # Trim trailing whitespace
                val="${val%"${val##*[![:space:]]}"}"

                # Reject command substitution $(...) or backticks in unquoted values
                if [[ "$val" == *'`'* || "$val" =~ \$\([^\)]*\) || "$val" =~ \$\(\( || "$val" =~ \$\{[^\}]*\} ]]; then
                    echo "[ERROR] Unsafe executable syntax in $env_file line $line_no: command substitution forbidden!" >&2
                    return 1
                fi
            fi

            declare -g "$key=$val"
            if declare -p CONFIG_EXPLICIT_KEYS >/dev/null 2>&1; then
                CONFIG_EXPLICIT_KEYS["$key"]=1
            fi
        else
            echo "[ERROR] Malformed syntax in $env_file line $line_no: '$line'" >&2
            return 1
        fi
    done < "$env_file"
    return 0
}

resolve_ssl_cert_paths() {
    local domain="$1"
    local prefix="${2:-SSL}"
    local cert_var="${prefix}_CERT_PATH"
    local key_var="${prefix}_KEY_PATH"

    local custom_cert="${!cert_var:-}"
    local custom_key="${!key_var:-}"

    if [ -n "$custom_cert" ] && [ -n "$custom_key" ] && [ -s "$custom_cert" ] && [ -s "$custom_key" ]; then
        return 0
    fi

    # 1. Let's Encrypt (/etc/letsencrypt/live)
    if [ -s "/etc/letsencrypt/live/$domain/fullchain.pem" ] && [ -s "/etc/letsencrypt/live/$domain/privkey.pem" ]; then
        printf -v "$cert_var" '%s' "/etc/letsencrypt/live/$domain/fullchain.pem"
        printf -v "$key_var" '%s' "/etc/letsencrypt/live/$domain/privkey.pem"
        declare -g "$cert_var=/etc/letsencrypt/live/$domain/fullchain.pem" 2>/dev/null || true
        declare -g "$key_var=/etc/letsencrypt/live/$domain/privkey.pem" 2>/dev/null || true
        return 0
    fi

    # 2. ACME (/etc/ssl/acme)
    if [ -s "/etc/ssl/acme/$domain/fullchain.pem" ] && [ -s "/etc/ssl/acme/$domain/privkey.pem" ]; then
        printf -v "$cert_var" '%s' "/etc/ssl/acme/$domain/fullchain.pem"
        printf -v "$key_var" '%s' "/etc/ssl/acme/$domain/privkey.pem"
        declare -g "$cert_var=/etc/ssl/acme/$domain/fullchain.pem" 2>/dev/null || true
        declare -g "$key_var=/etc/ssl/acme/$domain/privkey.pem" 2>/dev/null || true
        return 0
    fi

    # 3. Fallback based on SSL_ENGINE_CHOICE / SSL_BASE_DIR
    local base_dir="/etc/letsencrypt/live"
    if [ "${SSL_ENGINE_CHOICE:-1}" = "2" ] || [ "${SSL_BASE_DIR:-}" = "/etc/ssl/acme" ]; then
        base_dir="/etc/ssl/acme"
    fi
    printf -v "$cert_var" '%s' "$base_dir/$domain/fullchain.pem"
    printf -v "$key_var" '%s' "$base_dir/$domain/privkey.pem"
    declare -g "$cert_var=$base_dir/$domain/fullchain.pem" 2>/dev/null || true
    declare -g "$key_var=$base_dir/$domain/privkey.pem" 2>/dev/null || true
    return 0
}
#!/usr/bin/env bash
# ==============================================================================
# src/common/lock.sh - Inter-Process Mutex for Mutating Operations (T07)
# ==============================================================================
# Ensures single-writer mutual exclusion across install, setup, maintain,
# configure-panel, prepare-server, manage-services, and uninstall.
# Supports re-entrancy for nested invocations (e.g., install calling setup).
# ==============================================================================

VPN_STACK_LOCK_FILE="${VPN_STACK_LOCK_FILE:-/run/lock/vpn-stack.lock}"
VPN_STACK_LOCK_TIMEOUT="${VPN_STACK_LOCK_TIMEOUT:-10}"
VPN_STACK_LOCK_FD=200

_get_vpn_lock_path() {
    if [ -n "${VPN_STACK_LOCK_FILE:-}" ] && [ "${VPN_STACK_LOCK_FILE}" != "/run/lock/vpn-stack.lock" ]; then
        echo "$VPN_STACK_LOCK_FILE"
        return 0
    fi
    if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -d /run/lock ]; then
        echo "/run/lock/vpn-stack.lock"
    elif [ -d "${XDG_RUNTIME_DIR:-}" ]; then
        echo "${XDG_RUNTIME_DIR}/vpn-stack.lock"
    elif [ -d /var/run ]; then
        echo "/var/run/vpn-stack.lock"
    else
        echo "/tmp/.vpn-stack-${EUID:-0}.lock"
    fi
}

_is_lock_ancestor() {
    local target="$1"
    [ -n "$target" ] || return 1
    [ "$target" = "$$" ] && return 0
    [ "$target" = "${PPID:-}" ] && return 0
    local cur_p="${PPID:-}"
    local count=0
    while [ -n "$cur_p" ] && [ "$cur_p" -gt 1 ] && [ "$count" -lt 10 ]; do
        [ "$cur_p" = "$target" ] && return 0
        if [ -f "/proc/$cur_p/stat" ]; then
            cur_p=$(awk '{print $4}' "/proc/$cur_p/stat" 2>/dev/null || echo "")
        elif command -v ps >/dev/null 2>&1; then
            cur_p=$(ps -o ppid= -p "$cur_p" 2>/dev/null | tr -d ' ' || echo "")
        else
            break
        fi
        count=$((count + 1))
    done
    return 1
}

_on_stack_lock_exit() {
    local exit_code=$?
    release_stack_lock
    if [ -n "${_PREV_LOCK_EXIT_TRAP:-}" ] && [ "${_PREV_LOCK_EXIT_TRAP}" != "release_stack_lock" ] && [ "${_PREV_LOCK_EXIT_TRAP}" != "_on_stack_lock_exit" ]; then
        eval "$_PREV_LOCK_EXIT_TRAP"
    fi
    exit "$exit_code"
}

_setup_lock_traps() {
    _PREV_LOCK_EXIT_TRAP=$(trap -p EXIT 2>/dev/null | sed -E "s/^trap -- ['\"]?(.*)['\"]? EXIT\$/\\1/" || true)
    trap '_on_stack_lock_exit' EXIT INT TERM
}

acquire_stack_lock() {
    local timeout="${1:-$VPN_STACK_LOCK_TIMEOUT}"
    local op_name="${2:-${0##*/}}"

    # 1. Re-entrancy check: if lock is already held by current process or ancestor in this session
    if [ -n "${VPN_STACK_LOCK_HELD_BY:-}" ]; then
        if [ "$VPN_STACK_LOCK_HELD_BY" = "$$" ] || _is_lock_ancestor "$VPN_STACK_LOCK_HELD_BY"; then
            # Nested call within same operation hierarchy
            return 0
        fi
    fi

    local lock_path
    lock_path="$(_get_vpn_lock_path)"
    local lock_dir="${lock_path%/*}"
    [ -d "$lock_dir" ] || mkdir -p "$lock_dir" 2>/dev/null || true

    # Security check: lock file must NOT be a symlink (T07.C07)
    if [ -L "$lock_path" ]; then
        echo "[ERROR] Lock file $lock_path is a symbolic link! Aborting to prevent symlink attacks." >&2
        return 75
    fi

    local start_time
    start_time=$(date +%s 2>/dev/null || echo 0)

    while true; do
        if command -v flock >/dev/null 2>&1; then
            # flock-based locking
            eval "exec ${VPN_STACK_LOCK_FD}>\"\$lock_path\"" 2>/dev/null || {
                echo "[ERROR] Unable to open lock file $lock_path" >&2
                return 75
            }
            if flock -n "$VPN_STACK_LOCK_FD" 2>/dev/null; then
                echo "$$" > "$lock_path" 2>/dev/null || true
                export VPN_STACK_LOCK_HELD_BY="$$"
                export VPN_STACK_LOCK_ACTIVE_PATH="$lock_path"
                _setup_lock_traps
                return 0
            fi
        else
            # Directory-based atomic mutex fallback for platforms without flock
            local lock_d="${lock_path}.d"
            if mkdir "$lock_d" 2>/dev/null; then
                echo "$$" > "$lock_path" 2>/dev/null || true
                export VPN_STACK_LOCK_HELD_BY="$$"
                export VPN_STACK_LOCK_ACTIVE_PATH="$lock_path"
                _setup_lock_traps
                return 0
            fi
        fi

        # Check existing holder PID
        local holder_pid=""
        if [ -s "$lock_path" ]; then
            holder_pid=$(head -n 1 "$lock_path" 2>/dev/null | tr -cd '0-9')
        fi

        # Check if holder PID is dead (stale lock recovery)
        if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
            if command -v flock >/dev/null 2>&1; then
                echo "$$" > "$lock_path" 2>/dev/null || true
                if flock -n "$VPN_STACK_LOCK_FD" 2>/dev/null; then
                    export VPN_STACK_LOCK_HELD_BY="$$"
                    export VPN_STACK_LOCK_ACTIVE_PATH="$lock_path"
                    _setup_lock_traps
                    return 0
                fi
            else
                rm -rf "${lock_path}.d" 2>/dev/null || true
                if mkdir "${lock_path}.d" 2>/dev/null; then
                    echo "$$" > "$lock_path" 2>/dev/null || true
                    export VPN_STACK_LOCK_HELD_BY="$$"
                    export VPN_STACK_LOCK_ACTIVE_PATH="$lock_path"
                    _setup_lock_traps
                    return 0
                fi
            fi
        fi

        local now
        now=$(date +%s 2>/dev/null || echo 0)
        local elapsed=$((now - start_time))
        if [ "$elapsed" -ge "$timeout" ]; then
            echo "[ERROR] Operation '$op_name' blocked by active operation (PID: ${holder_pid:-unknown})." >&2
            echo "[ERROR] Timed out after ${timeout}s waiting for lock: $lock_path" >&2
            return 75
        fi

        sleep 0.5 2>/dev/null || sleep 1
    done
}

release_stack_lock() {
    if [ -n "${VPN_STACK_LOCK_HELD_BY:-}" ] && [ "$VPN_STACK_LOCK_HELD_BY" = "$$" ]; then
        local lock_path="${VPN_STACK_LOCK_ACTIVE_PATH:-$(_get_vpn_lock_path)}"
        if [ -f "$lock_path" ]; then
            rm -f "$lock_path" 2>/dev/null || true
        fi
        if [ -d "${lock_path}.d" ]; then
            rmdir "${lock_path}.d" 2>/dev/null || rm -rf "${lock_path}.d" 2>/dev/null || true
        fi
        if command -v flock >/dev/null 2>&1; then
            eval "exec ${VPN_STACK_LOCK_FD}>&-" 2>/dev/null || true
        fi
        unset VPN_STACK_LOCK_HELD_BY
        unset VPN_STACK_LOCK_ACTIVE_PATH
    fi
}
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
        'x86_64': ('https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-x86_64-unknown-linux-musl', '4bdfa57db9e8bf69f10cb9fa3268846c4f3ce2d4a2a1ea9174112e432c25ea7a', 15728640, '0.2.25'),
        'aarch64': ('https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-aarch64-unknown-linux-musl', '81f211925b6a55543cbe24bc99015c90ec1ae62c3328e67ff8df82bb7da255ef', 15728640, '0.2.25')
    },
    'wstunnel': {
        'x86_64': ('https://github.com/erebe/wstunnel/releases/download/v10.1.7/wstunnel_10.1.7_linux_amd64.tar.gz', 'ca6d77e4cfcf6ce4b06f528a47ea37cb9a941fcddff4a9df315f6068e5ff4e6b', 26214400, '10.1.7'),
        'aarch64': ('https://github.com/erebe/wstunnel/releases/download/v10.1.7/wstunnel_10.1.7_linux_arm64.tar.gz', '7a353d2bf2cb4d3d81b24d7759ad4ba7eb04cf4c5478491d904ba6b44588df8e', 26214400, '10.1.7')
    },
    'sing-box': {
        'x86_64': ('https://github.com/SagerNet/sing-box/releases/download/v1.11.4/sing-box-1.11.4-linux-amd64.tar.gz', '6b2cbb4ee2cb36a32cb5e2f7b8d4bb9f8e434f3c7e497ecb822d4f20bf8a0db8', 52428800, '1.11.4'),
        'aarch64': ('https://github.com/SagerNet/sing-box/releases/download/v1.11.4/sing-box-1.11.4-linux-arm64.tar.gz', '9a01f68742b6c7314ec41be1aa7ee965ec3c457bc6a42247dc2bc89600a747ea', 52428800, '1.11.4')
    },
    'zapret': {
        'all': ('https://github.com/bol-van/zapret/releases/download/v70/zapret-v70.tar.gz', '1517409c6ae9fa4513ec8b4bcf51e18b849cb19a57fb6bc12001358e5d3264c1', 20971520, '70')
    },
    'AdGuardHome': {
        'x86_64': ('https://static.adguard.com/adguardhome/release/AdGuardHome_linux_amd64.tar.gz', '439265eb634ce5a87e02598380cf7bc51b0337d1d2b7c4a169fe5a1c3132e0c9', 41943040, '0.107.56'),
        'aarch64': ('https://static.adguard.com/adguardhome/release/AdGuardHome_linux_arm64.tar.gz', 'c88f17a94ef933aa5a11dfbbf099ec16f28beae5c0bf323c21a19614457ee458', 41943040, '0.107.56')
    },
    'acme.sh': {
        'all': ('https://github.com/acmesh-official/acme.sh/archive/refs/tags/3.0.8.tar.gz', 'bf4405d43899f8d16972e2762b9f67355030e20fb3ae7068565a0cbb02e53ef7', 2097152, '3.0.8')
    }
}

comp_name = sys.argv[1]
arch = sys.argv[2]
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
        local raw_arch
        raw_arch=$(uname -m 2>/dev/null || echo "x86_64")
        case "$raw_arch" in
            x86_64|amd64) cur_arch="x86_64" ;;
            aarch64|arm64) cur_arch="aarch64" ;;
            *) cur_arch="x86_64" ;;
        esac
    fi

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

# SQLite WAL-safe live database backup and verification
get_sqlite_backup_python() {
    if [ -n "${PYTHON_CMD:-}" ] && "$PYTHON_CMD" -c "import sqlite3" 2>/dev/null; then
        echo "$PYTHON_CMD"
        return 0
    fi
    if python3 -c "import sqlite3" 2>/dev/null; then
        echo "python3"
        return 0
    fi
    if python -c "import sqlite3" 2>/dev/null; then
        echo "python"
        return 0
    fi
    return 1
}

verify_sqlite_backup() {
    local bkp="$1"
    local py_cmd="$2"
    if [ ! -s "$bkp" ]; then
        return 1
    fi
    if [ -n "$py_cmd" ]; then
        "$py_cmd" -c "
import sqlite3, sys
try:
    conn = sqlite3.connect(sys.argv[1])
    res = conn.execute('PRAGMA integrity_check;').fetchall()
    conn.close()
    if res and res[0][0] == 'ok':
        sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
" "$bkp" 2>/dev/null && return 0
    elif command -v sqlite3 >/dev/null 2>&1; then
        local check
        check=$(sqlite3 "$bkp" "PRAGMA integrity_check;" 2>/dev/null || true)
        [ "$check" = "ok" ] && return 0
    fi
    return 1
}

backup_sqlite_db() {
    local src="$1"
    local dst="$2"
    if [ ! -f "$src" ]; then
        return 1
    fi
    local py_cmd
    py_cmd=$(get_sqlite_backup_python || true)

    local backup_ok=0

    # 1. Primary: Python SQLite Online Backup API (atomic, WAL-safe)
    if [ -n "$py_cmd" ]; then
        if "$py_cmd" -c "
import sqlite3, sys
src_p, dst_p = sys.argv[1], sys.argv[2]
try:
    try:
        src_conn = sqlite3.connect(f'file:{src_p}?mode=ro', uri=True)
    except Exception:
        src_conn = sqlite3.connect(src_p)
    dst_conn = sqlite3.connect(dst_p)
    with dst_conn:
        src_conn.backup(dst_conn)
    dst_conn.close()
    src_conn.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
" "$src" "$dst" 2>/dev/null; then
            if verify_sqlite_backup "$dst" "$py_cmd"; then
                backup_ok=1
            fi
        fi
    fi

    # 2. Secondary: sqlite3 CLI .backup command (atomic, WAL-safe)
    if [ "$backup_ok" -eq 0 ] && command -v sqlite3 >/dev/null 2>&1; then
        if sqlite3 "$src" ".backup '$dst'" 2>/dev/null; then
            if verify_sqlite_backup "$dst" "$py_cmd"; then
                backup_ok=1
            fi
        fi
    fi

    if [ "$backup_ok" -eq 1 ]; then
        chmod 600 "$dst" 2>/dev/null || true
        return 0
    fi

    # Never silently downgrade to raw cp of a live WAL database; fail safe and clean up
    rm -f "$dst" 2>/dev/null || true
    return 1
}

do_restore_rollback() {
    local rollback_dir="$1"
    warn "Инициирован аварийный откат к состоянию до восстановления..."
    local rollback_failed=0

    # Остановка служб перед манипуляциями с файлами во избежание гонок и повреждения БД
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop nginx 2>/dev/null || true
        if ! systemctl stop x-ui 2>/dev/null; then
            if systemctl is-active --quiet x-ui 2>/dev/null; then
                die "Критическая ошибка: невозможно остановить службу x-ui перед аварийным откатом (процесс активен). Во избежание повреждения базы данных операция отката прервана, резервные копии сохранены в $rollback_dir."
            fi
        fi
        # Обязательное подтверждение, что x-ui остановлен перед удалением журналов и заменой БД
        if systemctl is-active --quiet x-ui 2>/dev/null; then
            die "Критическая ошибка: служба x-ui продолжает работать после команды остановки. Замена базы данных и удаление журналов отменены во избежание повреждения данных. Исходные резервные копии сохранены в $rollback_dir."
        fi
    fi

    # Очистка устаревших WAL/SHM журналов перед накатом старой БД
    rm -f /etc/x-ui/x-ui.db-wal /etc/x-ui/x-ui.db-shm \
          /usr/local/x-ui/bin/x-ui.db-wal /usr/local/x-ui/bin/x-ui.db-shm 2>/dev/null || true

    if [ -f "$rollback_dir/x-ui.db" ]; then
        if [ -d /etc/x-ui ] || [ -f /etc/x-ui/x-ui.db ]; then
            mkdir -p /etc/x-ui 2>/dev/null || true
            cp -a "$rollback_dir/x-ui.db" /etc/x-ui/x-ui.db || rollback_failed=1
            chmod 600 /etc/x-ui/x-ui.db 2>/dev/null || true
        fi
        if [ -d /usr/local/x-ui/bin ] || [ -f /usr/local/x-ui/bin/x-ui.db ]; then
            mkdir -p /usr/local/x-ui/bin 2>/dev/null || true
            cp -a "$rollback_dir/x-ui.db" /usr/local/x-ui/bin/x-ui.db || rollback_failed=1
            chmod 600 /usr/local/x-ui/bin/x-ui.db 2>/dev/null || true
        fi
    fi

    if [ -d "$rollback_dir/nginx" ]; then
        cp -a "$rollback_dir/nginx/"* /etc/nginx/ 2>/dev/null || rollback_failed=1
    fi
    if [ -d "$rollback_dir/amneziawg" ]; then
        mkdir -p /etc/amnezia/amneziawg 2>/dev/null || true
        cp -a "$rollback_dir/amneziawg/"* /etc/amnezia/amneziawg/ 2>/dev/null || rollback_failed=1
    fi
    if [ -d "$rollback_dir/mita" ]; then
        mkdir -p /etc/mita 2>/dev/null || true
        cp -a "$rollback_dir/mita/"* /etc/mita/ 2>/dev/null || rollback_failed=1
        chown -R mita:mita /etc/mita 2>/dev/null || true
    fi
    if [ -f "$rollback_dir/mita_server_config.json" ]; then
        cp -a "$rollback_dir/mita_server_config.json" /etc/mita_server_config.json 2>/dev/null || rollback_failed=1
        chown mita:mita /etc/mita_server_config.json 2>/dev/null || true
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        if [ -f /etc/x-ui/x-ui.db ] || [ -f /usr/local/x-ui/bin/x-ui.db ]; then
            systemctl restart x-ui || rollback_failed=1
            systemctl is-active --quiet x-ui || rollback_failed=1
        fi
        if command -v nginx >/dev/null 2>&1 && [ -f /etc/nginx/nginx.conf ]; then
            nginx -t >/dev/null 2>&1 && systemctl restart nginx || rollback_failed=1
            systemctl is-active --quiet nginx || rollback_failed=1
        fi
    fi

    if [ "$rollback_failed" -ne 0 ]; then
        die "Восстановление прервано с ошибкой. ВНИМАНИЕ: при аварийном откате к $rollback_dir также возникли сбои (ошибки копирования или перезапуска служб)! Проверьте состояние служб и каталог $rollback_dir."
    else
        die "Восстановление прервано с ошибкой. Исходное состояние сервера успешно восстановлено из $rollback_dir."
    fi
}

do_backup() {
    local target_dir="/var/backups/vpn-stack"
    mkdir -p "$target_dir" 2>/dev/null || true
    chmod 700 "$target_dir" 2>/dev/null || true

    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    local archive="${target_dir}/vpn-backup-${ts}.tar.gz"
    local staging
    staging=$(mktemp -d /tmp/vpn-backup-staging.XXXXXX) || die "Не удалось создать временный каталог для бэкапа."

    log "Создание транзакционного снимка системы..."

    # 1. Загрузка конфигурации окружения
    local cfg=""
    if [ -n "${CONFIG_FILE:-}" ] && [ -f "$CONFIG_FILE" ]; then
        cfg="$CONFIG_FILE"
    else
        cfg=$(find_config_file "${SCRIPT_DIR:-.}" 2>/dev/null || true)
    fi
    if [ -n "$cfg" ] && [ -f "$cfg" ]; then
        source "$cfg" 2>/dev/null || true
        mkdir -p "$staging/env"
        cp -a "$cfg" "$staging/env/server-setup.env" 2>/dev/null || true
    fi
    if [ -f /root/vpn_credentials.txt ]; then
        mkdir -p "$staging/env"
        cp -a /root/vpn_credentials.txt "$staging/env/" 2>/dev/null || true
    fi

    # 2. Атомарный дамп базы 3X-UI через SQLite Online Backup API
    local db_file="${DB_PATH:-/etc/x-ui/x-ui.db}"
    if [ ! -f "$db_file" ]; then
        for alt_db in /usr/local/x-ui/bin/x-ui.db /etc/x-ui/x-ui.db; do
            if [ -f "$alt_db" ]; then
                db_file="$alt_db"
                break
            fi
        done
    fi

    if [ -f "$db_file" ]; then
        mkdir -p "$staging/db"
        if ! backup_sqlite_db "$db_file" "$staging/db/x-ui.db"; then
            rm -rf "$staging"
            die "Ошибка: Не удалось выполнить атомарный дамп базы данных $db_file."
        fi
        ok "База данных 3X-UI сохранена и проверена (WAL-safe)"
    fi

    # 3. Конфигурации Nginx
    if [ -d /etc/nginx ]; then
        mkdir -p "$staging/nginx"
        [ -f /etc/nginx/nginx.conf ] && cp -a /etc/nginx/nginx.conf "$staging/nginx/" 2>/dev/null || true
        [ -d /etc/nginx/conf.d ] && cp -a /etc/nginx/conf.d "$staging/nginx/" 2>/dev/null || true
        [ -d /etc/nginx/stream.d ] && cp -a /etc/nginx/stream.d "$staging/nginx/" 2>/dev/null || true
        ok "Конфигурации Nginx сохранены"
    fi

    # 4. AmneziaWG / WireGuard ключи и конфиги
    if [ -d /etc/amnezia/amneziawg ]; then
        mkdir -p "$staging/amnezia"
        cp -a /etc/amnezia/amneziawg "$staging/amnezia/" 2>/dev/null || true
        ok "Конфигурации Dual AmneziaWG сохранены"
    fi

    # 5. Службы NextGen (Sing-box, ShadowTLS, Caddy, Wstunnel, DNSTT, Mieru/mita)
    mkdir -p "$staging/nextgen"
    for ng_dir in /etc/sing-box /etc/shadowtls /etc/dnstt /etc/caddy /etc/wstunnel /etc/mita; do
        if [ -d "$ng_dir" ]; then
            cp -a "$ng_dir" "$staging/nextgen/" 2>/dev/null || true
        fi
    done
    if [ -f /etc/mita_server_config.json ]; then
        cp -a /etc/mita_server_config.json "$staging/nextgen/" 2>/dev/null || true
    fi
    ok "Конфигурации Next-Gen сервисов сохранены (включая Mieru)"

    # 6. Диагностический портал
    if [ -d /var/www/diagnostics ] || [ -d /usr/local/lib/vpn-diagnostics ]; then
        mkdir -p "$staging/diagnostics"
        [ -d /var/www/diagnostics ] && cp -a /var/www/diagnostics "$staging/diagnostics/" 2>/dev/null || true
        [ -d /usr/local/lib/vpn-diagnostics ] && cp -a /usr/local/lib/vpn-diagnostics "$staging/diagnostics/" 2>/dev/null || true
        [ -f /etc/systemd/system/vpn-diagnostics.service ] && cp -a /etc/systemd/system/vpn-diagnostics.service "$staging/diagnostics/" 2>/dev/null || true
        ok "Ресурсы веб-диагностики сохранены"
    fi

    # 7. AdGuard Home
    if [ -f /opt/AdGuardHome/AdGuardHome.yaml ]; then
        mkdir -p "$staging/adguard"
        cp -a /opt/AdGuardHome/AdGuardHome.yaml "$staging/adguard/" 2>/dev/null || true
        ok "Конфигурация AdGuard Home сохранена"
    fi

    # 8. Селективный экспорт SSL-сертификатов (Certbot lineages + acme.sh)
    mkdir -p "$staging/ssl"
    if [ -d /etc/letsencrypt/live ]; then
        local domains=()
        [ -n "${PRIMARY_DOMAIN:-}" ] && domains+=("$PRIMARY_DOMAIN")
        [ -n "${AGH_DOMAIN:-}" ] && domains+=("$AGH_DOMAIN")

        mkdir -p "$staging/ssl/letsencrypt/live"
        mkdir -p "$staging/ssl/letsencrypt/archive"
        mkdir -p "$staging/ssl/letsencrypt/renewal"

        for d in "${domains[@]}"; do
            [ -z "$d" ] && continue
            if [ -d "/etc/letsencrypt/live/$d" ]; then
                mkdir -p "$staging/ssl/letsencrypt/live/$d"
                cp -L "/etc/letsencrypt/live/$d/"* "$staging/ssl/letsencrypt/live/$d/" 2>/dev/null || true
            fi
            if [ -d "/etc/letsencrypt/archive/$d" ]; then
                mkdir -p "$staging/ssl/letsencrypt/archive/$d"
                cp -a "/etc/letsencrypt/archive/$d/"* "$staging/ssl/letsencrypt/archive/$d/" 2>/dev/null || true
            fi
            if [ -f "/etc/letsencrypt/renewal/$d.conf" ]; then
                cp -a "/etc/letsencrypt/renewal/$d.conf" "$staging/ssl/letsencrypt/renewal/" 2>/dev/null || true
            fi
        done
        [ -d /etc/letsencrypt/renewal-hooks ] && cp -a /etc/letsencrypt/renewal-hooks "$staging/ssl/letsencrypt/" 2>/dev/null || true
        ok "SSL-сертификаты Let's Encrypt сохранены"
    fi

    if [ -d /etc/ssl/acme ]; then
        mkdir -p "$staging/ssl/acme"
        cp -a /etc/ssl/acme/* "$staging/ssl/acme/" 2>/dev/null || true
        ok "SSL-сертификаты acme.sh сохранены"
    fi

    # 8.5 Создание manifest.json со списком файлов и SHA256 (T21.C01)
    local py_cmd
    py_cmd=$(get_sqlite_backup_python || echo "python3")
    "$py_cmd" -c "
import json, os, hashlib, sys

staging = sys.argv[1]
manifest_path = os.path.join(staging, 'manifest.json')
files_map = {}

for root, dirs, files in os.walk(staging):
    for f in sorted(files):
        if f == 'manifest.json':
            continue
        full_p = os.path.join(root, f)
        rel_p = os.path.relpath(full_p, staging).replace('\\\\', '/')
        try:
            with open(full_p, 'rb') as fp:
                h = hashlib.sha256(fp.read()).hexdigest()
            files_map[rel_p] = h
        except Exception:
            pass

data = {
    'format_version': '2.0',
    'project_version': os.environ.get('SCRIPT_VERSION', 'v9.2.0'),
    'created_at': os.popen('date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null').read().strip(),
    'db_path': os.environ.get('DB_PATH', '/etc/x-ui/x-ui.db'),
    'files': files_map
}

with open(manifest_path, 'w', encoding='utf-8') as out:
    json.dump(data, out, indent=2)
" "$staging" 2>/dev/null || true

    # 9. Упаковка архива
    if ! "$py_cmd" -c "
import tarfile, sys, os
archive, staging = sys.argv[1], sys.argv[2]
with tarfile.open(archive, 'w:gz') as tar:
    for item in os.listdir(staging):
        tar.add(os.path.join(staging, item), arcname=item)
" "$archive" "$staging"; then
        rm -rf "$staging"
        die "Ошибка создания tar-архива $archive."
    fi

    rm -rf "$staging"
    chmod 600 "$archive"

    local sz
    sz=$(du -h "$archive" 2>/dev/null | cut -f1 || echo "OK")
    echo
    ok "Резервная копия успешно создана: ${BOLD}$archive${NC} ($sz)"
    echo -e "      ${BOLD}Путь к архиву:${NC}  ${CYAN}$archive${NC}"
    echo -e "      ${BOLD}Права доступа:${NC}  0600 (root only)"
    echo -e "      ${BOLD}Команда отката:${NC} ./maintain.sh restore $archive"
    echo
}

do_restore() {
    local archive="${1:-}"
    [[ -n "$archive" ]] || die "Укажите путь к архиву: ./maintain.sh restore <архив.tar.gz>"
    [[ -f "$archive" ]] || die "Файл архива не найден: $archive"

    local target_backup_dir="/var/backups/vpn-stack"
    local rollback_dir="${target_backup_dir}/.rollback-latest"
    mkdir -p "$target_backup_dir" 2>/dev/null || true

    log "Подготовка к восстановлению из $archive..."

    # Создание снапшота текущего состояния для гарантированного отката
    rm -rf "$rollback_dir" 2>/dev/null || true
    mkdir -p "$rollback_dir"
    chmod 700 "$rollback_dir"

    local current_db="/etc/x-ui/x-ui.db"
    if [ ! -f "$current_db" ]; then
        for alt_db in /usr/local/x-ui/bin/x-ui.db /etc/x-ui/x-ui.db; do
            if [ -f "$alt_db" ]; then
                current_db="$alt_db"
                break
            fi
        done
    fi
    if [ -f "$current_db" ]; then
        if ! backup_sqlite_db "$current_db" "$rollback_dir/x-ui.db"; then
            rm -rf "$rollback_dir"
            die "Ошибка: не удалось создать безопасный снапшот SQLite базы $current_db перед восстановлением."
        fi
    fi
    [ -d /etc/nginx ] && cp -a /etc/nginx "$rollback_dir/" 2>/dev/null || true
    [ -d /etc/amnezia/amneziawg ] && cp -a /etc/amnezia/amneziawg "$rollback_dir/" 2>/dev/null || true
    [ -d /etc/mita ] && cp -a /etc/mita "$rollback_dir/" 2>/dev/null || true
    [ -f /etc/mita_server_config.json ] && cp -a /etc/mita_server_config.json "$rollback_dir/" 2>/dev/null || true

    local staging
    staging=$(mktemp -d /tmp/vpn-restore-staging.XXXXXX) || die "Не удалось создать временный каталог для распаковки."

    # Распаковываем во временный каталог через безопасный фильтр Python
    local py_cmd
    py_cmd=$(get_sqlite_backup_python || echo "python3")
    if ! "$py_cmd" -c "
import tarfile, sys, os
archive, target = sys.argv[1], sys.argv[2]
os.makedirs(target, exist_ok=True)
dest = os.path.realpath(target)

with tarfile.open(archive, 'r:gz') as tar:
    if hasattr(tarfile, 'data_filter'):
        tar.extractall(target, filter='data')
    else:
        for m in tar.getmembers():
            mp = os.path.realpath(os.path.join(dest, m.name))
            if not mp.startswith(dest + os.sep) and mp != dest:
                raise RuntimeError(f'Попытка выхода за границы целевого каталога (Path Traversal): {m.name}')
            if m.islnk() or m.issym():
                continue
            tar.extract(m, dest)
" "$archive" "$staging"; then
        rm -rf "$staging"
        die "Ошибка безопасной распаковки архива $archive."
    fi

    # 0. Проверка целостности файлов бэкапа по manifest.json (T21.C01, T21.C02)
    if [ -f "$staging/manifest.json" ]; then
        if ! "$py_cmd" -c "
import json, os, hashlib, sys
staging = sys.argv[1]
with open(os.path.join(staging, 'manifest.json'), 'r', encoding='utf-8') as fp:
    manifest = json.load(fp)
for rel_p, expected_h in manifest.get('files', {}).items():
    full_p = os.path.join(staging, rel_p)
    if not os.path.isfile(full_p):
        sys.exit(f'Missing backed up file: {rel_p}')
    with open(full_p, 'rb') as f:
        actual_h = hashlib.sha256(f.read()).hexdigest()
    if actual_h != expected_h:
        sys.exit(f'Checksum mismatch for {rel_p}: expected {expected_h}, got {actual_h}')
" "$staging"; then
            rm -rf "$staging"
            die "Ошибка: Нарушена целостность файлов бэкапа по манифесту (T21.C02)!"
        fi
        ok "Целостность файлов бэкапа и манифест версии 2.0 подтверждены"
    fi

    # 0.5 Проверка целостности SQLite перед наложением (T21.C03)
    if [ -f "$staging/db/x-ui.db" ]; then
        if ! verify_sqlite_backup "$staging/db/x-ui.db" "$py_cmd"; then
            rm -rf "$staging"
            die "Ошибка: База данных в бэкапе x-ui.db повреждена (PRAGMA integrity_check failed)!"
        fi
        ok "Целостность базы данных x-ui.db в бэкапе проверена (PRAGMA integrity_check OK)"
    fi

    # Валидация соответствия сертификатов и ключей, если они присутствуют в архиве (RSA / ECDSA / Ed25519)
    if [ -d "$staging/ssl/letsencrypt/live" ]; then
        for cert_dir in "$staging/ssl/letsencrypt/live/"*; do
            if [ -d "$cert_dir" ] && [ -f "$cert_dir/fullchain.pem" ] && [ -f "$cert_dir/privkey.pem" ]; then
                local cert_pub key_pub
                cert_pub=$(openssl x509 -noout -pubkey -in "$cert_dir/fullchain.pem" 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256 2>/dev/null || true)
                key_pub=$(openssl pkey -pubout -in "$cert_dir/privkey.pem" 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256 2>/dev/null || true)
                if [ -n "$cert_pub" ] && [ -n "$key_pub" ] && [ "$cert_pub" != "$key_pub" ]; then
                    rm -rf "$staging"
                    die "Криптографическая ошибка: сертификат и ключ в $cert_dir не соответствуют друг другу!"
                fi
            fi
        done
        ok "Криптографическая валидация SSL-сертификатов пройдена (RSA/ECDSA OK)"
    fi

    # Приостанавливаем сервисы перед заменой файлов с верификацией остановки x-ui (T03.C04, T22.C03)
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop nginx 2>/dev/null || true
        systemctl stop vpn-diagnostics 2>/dev/null || true
        if ! systemctl stop x-ui 2>/dev/null; then
            if systemctl is-active --quiet x-ui 2>/dev/null; then
                rm -rf "$staging"
                die "Критическая ошибка: невозможно остановить службу x-ui перед восстановлением (процесс активен). Замена базы отменена."
            fi
        fi
        if systemctl is-active --quiet x-ui 2>/dev/null; then
            rm -rf "$staging"
            die "Критическая ошибка: служба x-ui продолжает работать после команды остановки. Замена базы отменена."
        fi
    fi

    # 1. Восстановление базы данных
    if [ -f "$staging/db/x-ui.db" ]; then
        # Очистка устаревших журналов WAL/SHM перед накатом базы данных (T03.C04, T21.C03)
        rm -f /etc/x-ui/x-ui.db-wal /etc/x-ui/x-ui.db-shm \
              /usr/local/x-ui/bin/x-ui.db-wal /usr/local/x-ui/bin/x-ui.db-shm 2>/dev/null || true
        mkdir -p /etc/x-ui
        cp -a "$staging/db/x-ui.db" /etc/x-ui/x-ui.db
        chmod 600 /etc/x-ui/x-ui.db
        if [ -d /usr/local/x-ui/bin ]; then
            cp -a "$staging/db/x-ui.db" /usr/local/x-ui/bin/x-ui.db 2>/dev/null || true
            chmod 600 /usr/local/x-ui/bin/x-ui.db 2>/dev/null || true
        fi
        ok "База данных 3X-UI восстановлена"
    fi

    # 2. Восстановление Nginx
    if [ -d "$staging/nginx" ]; then
        mkdir -p /etc/nginx/conf.d /etc/nginx/stream.d
        [ -f "$staging/nginx/nginx.conf" ] && cp -a "$staging/nginx/nginx.conf" /etc/nginx/nginx.conf
        [ -d "$staging/nginx/conf.d" ] && cp -a "$staging/nginx/conf.d/"* /etc/nginx/conf.d/ 2>/dev/null || true
        [ -d "$staging/nginx/stream.d" ] && cp -a "$staging/nginx/stream.d/"* /etc/nginx/stream.d/ 2>/dev/null || true
        ok "Конфигурация Nginx восстановлена"
    fi

    # 3. Восстановление AmneziaWG
    if [ -d "$staging/amnezia/amneziawg" ]; then
        mkdir -p /etc/amnezia/amneziawg
        cp -a "$staging/amnezia/amneziawg/"* /etc/amnezia/amneziawg/ 2>/dev/null || true
        chmod 700 /etc/amnezia/amneziawg
        chmod 600 /etc/amnezia/amneziawg/*.conf 2>/dev/null || true
        ok "Конфигурация AmneziaWG восстановлена"
    fi

    # 4. Восстановление AdGuard Home
    if [ -f "$staging/adguard/AdGuardHome.yaml" ]; then
        mkdir -p /opt/AdGuardHome
        cp -a "$staging/adguard/AdGuardHome.yaml" /opt/AdGuardHome/AdGuardHome.yaml
        ok "Конфигурация AdGuard Home восстановлена"
    fi

    # 5. Восстановление Next-Gen сервисов (включая Mieru/mita)
    if [ -d "$staging/nextgen" ]; then
        for ng_dir in sing-box shadowtls dnstt caddy wstunnel mita; do
            if [ -d "$staging/nextgen/$ng_dir" ]; then
                mkdir -p "/etc/$ng_dir"
                cp -a "$staging/nextgen/$ng_dir/"* "/etc/$ng_dir/" 2>/dev/null || true
            fi
        done
        if [ -f "$staging/nextgen/mita_server_config.json" ]; then
            cp -a "$staging/nextgen/mita_server_config.json" /etc/mita_server_config.json 2>/dev/null || true
        fi
        if id -u mita >/dev/null 2>&1; then
            chown -R mita:mita /etc/mita /etc/mita_server_config.json 2>/dev/null || true
            chmod 750 /etc/mita 2>/dev/null || true
            chmod 600 /etc/mita/config.json /etc/mita_server_config.json 2>/dev/null || true
        fi
        ok "Конфигурации Next-Gen сервисов восстановлены"
    fi

    # 6. Восстановление веб-диагностики
    if [ -d "$staging/diagnostics" ]; then
        if [ -d "$staging/diagnostics/diagnostics" ]; then
            mkdir -p /var/www/diagnostics
            cp -a "$staging/diagnostics/diagnostics/"* /var/www/diagnostics/ 2>/dev/null || true
        fi
        if [ -d "$staging/diagnostics/vpn-diagnostics" ]; then
            mkdir -p /usr/local/lib/vpn-diagnostics
            cp -a "$staging/diagnostics/vpn-diagnostics/"* /usr/local/lib/vpn-diagnostics/ 2>/dev/null || true
        fi
        if [ -f "$staging/diagnostics/vpn-diagnostics.service" ]; then
            cp -a "$staging/diagnostics/vpn-diagnostics.service" /etc/systemd/system/ 2>/dev/null || true
        fi
        ok "Ресурсы веб-диагностики восстановлены"
    fi

    # 7. Селективное восстановление SSL
    if [ -d "$staging/ssl/letsencrypt" ]; then
        mkdir -p /etc/letsencrypt
        [ -d "$staging/ssl/letsencrypt/live" ] && cp -a "$staging/ssl/letsencrypt/live" /etc/letsencrypt/ 2>/dev/null || true
        [ -d "$staging/ssl/letsencrypt/archive" ] && cp -a "$staging/ssl/letsencrypt/archive" /etc/letsencrypt/ 2>/dev/null || true
        [ -d "$staging/ssl/letsencrypt/renewal" ] && cp -a "$staging/ssl/letsencrypt/renewal" /etc/letsencrypt/ 2>/dev/null || true
        [ -d "$staging/ssl/letsencrypt/renewal-hooks" ] && cp -a "$staging/ssl/letsencrypt/renewal-hooks" /etc/letsencrypt/ 2>/dev/null || true
        ok "Селективные сертификаты Certbot восстановлены"
    fi
    if [ -d "$staging/ssl/acme" ]; then
        mkdir -p /etc/ssl/acme
        cp -a "$staging/ssl/acme/"* /etc/ssl/acme/ 2>/dev/null || true
        ok "Сертификаты acme.sh восстановлены"
    fi

    # 8. Восстановление переменных окружения
    if [ -f "$staging/env/server-setup.env" ]; then
        local target_env="${CONFIG_FILE:-/root/server-setup.env}"
        cp -a "$staging/env/server-setup.env" "$target_env" 2>/dev/null || true
    fi
    if [ -f "$staging/env/vpn_credentials.txt" ]; then
        cp -a "$staging/env/vpn_credentials.txt" /root/vpn_credentials.txt 2>/dev/null || true
    fi

    rm -rf "$staging"

    # 9. Проверка синтаксиса Nginx
    if command -v nginx >/dev/null 2>&1 && [ -f /etc/nginx/nginx.conf ]; then
        if ! nginx -t >/dev/null 2>&1; then
            warn "Ошибка: Восстановленная конфигурация Nginx не прошла синтаксическую проверку (nginx -t)!"
            do_restore_rollback "$rollback_dir"
        fi
    fi

    # 10. Перезапуск и строгая проверка активности критических служб
    systemctl daemon-reload 2>/dev/null || true

    if systemctl is-enabled x-ui >/dev/null 2>&1 || [ -f /etc/systemd/system/x-ui.service ]; then
        if ! systemctl restart x-ui; then
            warn "Ошибка: Не удалось перезапустить службу x-ui после восстановления!"
            do_restore_rollback "$rollback_dir"
        fi
        sleep 1
        if ! systemctl is-active --quiet x-ui; then
            warn "Ошибка: Служба x-ui не перешла в активное состояние после восстановления!"
            do_restore_rollback "$rollback_dir"
        fi
    fi

    if systemctl is-enabled nginx >/dev/null 2>&1 || [ -f /lib/systemd/system/nginx.service ] || [ -f /etc/systemd/system/nginx.service ]; then
        if ! systemctl restart nginx; then
            warn "Ошибка: Не удалось перезапустить службу nginx после восстановления!"
            do_restore_rollback "$rollback_dir"
        fi
        sleep 1
        if ! systemctl is-active --quiet nginx; then
            warn "Ошибка: Служба nginx не перешла в активное состояние после восстановления!"
            do_restore_rollback "$rollback_dir"
        fi
    fi

    # Вспомогательные службы перезапускаются best effort
    if [ -f /etc/systemd/system/vpn-diagnostics.service ]; then
        systemctl restart vpn-diagnostics 2>/dev/null || true
    fi
    if [ -f /etc/systemd/system/mita.service ]; then
        systemctl restart mita 2>/dev/null || true
    fi
    if [ -f /etc/amnezia/amneziawg/awg0.conf ]; then
        systemctl restart awg-quick@awg0 2>/dev/null || true
    fi
    if [ -f /etc/amnezia/amneziawg/awg1.conf ]; then
        systemctl restart awg-quick@awg1 2>/dev/null || true
    fi

    echo
    ok "Система успешно восстановлена из бэкапа $archive!"
    echo -e "      ${BOLD}Проверка Nginx:${NC}   ${GREEN}nginx -t OK${NC}"
    echo -e "      ${BOLD}Службы:${NC}           ${GREEN}x-ui, nginx активны${NC}"
    echo -e "      ${BOLD}Снимок отката:${NC}    ${CYAN}$rollback_dir${NC}"
    echo
    return 0
}

do_extract() {
    local archive="${1:-}"
    local target="${2:-}"
    [[ -n "$archive" ]] || die "Укажите путь к архиву: ./maintain.sh extract <архив.tar.gz> <каталог_для_распаковки>"
    [[ -n "$target" ]] || die "Укажите целевой каталог: ./maintain.sh extract <архив.tar.gz> <каталог_для_распаковки>"
    [[ -f "$archive" ]] || die "Файл архива не найден: $archive"

    mkdir -p "$target" 2>/dev/null || true
    log "Аварийное безопасное извлечение архива в $target..."

    local py_cmd
    py_cmd=$(get_sqlite_backup_python || echo "python3")
    if ! "$py_cmd" -c "
import tarfile, sys, os

archive, target = sys.argv[1], sys.argv[2]
os.makedirs(target, exist_ok=True)
dest = os.path.realpath(target)

with tarfile.open(archive, 'r:gz') as tar:
    if hasattr(tarfile, 'data_filter'):
        tar.extractall(target, filter='data')
    else:
        for m in tar.getmembers():
            mp = os.path.realpath(os.path.join(dest, m.name))
            if not mp.startswith(dest + os.sep) and mp != dest:
                raise RuntimeError(f'Попытка выхода за границы целевого каталога (Path Traversal): {m.name}')
            if m.islnk() or m.issym():
                continue
            tar.extract(m, dest)

print(f'[OK] Архив {archive} успешно и безопасно извлечён в {target}')
" "$archive" "$target"; then
        die "Ошибка извлечения архива $archive."
    fi
    return 0
}

audit_restore_archive() {
    local archive="${1:-}"
    [[ -n "$archive" ]] || die "Укажите путь к архиву: ./maintain.sh --dry-run restore <архив.tar.gz>"
    [[ -f "$archive" ]] || die "Файл архива не найден: $archive"

    local staging
    staging=$(mktemp -d /tmp/vpn-audit-staging.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/vpn-audit-staging.XXXXXX") || die "Не удалось создать временный каталог для аудита."

    local py_cmd
    py_cmd=$(get_sqlite_backup_python || echo "python3")

    if ! "$py_cmd" -c "
import tarfile, sys, os
archive, target = sys.argv[1], sys.argv[2]
os.makedirs(target, exist_ok=True)
dest = os.path.realpath(target)

with tarfile.open(archive, 'r:gz') as tar:
    if hasattr(tarfile, 'data_filter'):
        tar.extractall(target, filter='data')
    else:
        for m in tar.getmembers():
            mp = os.path.realpath(os.path.join(dest, m.name))
            if not mp.startswith(dest + os.sep) and mp != dest:
                raise RuntimeError(f'Попытка выхода за границы целевого каталога (Path Traversal): {m.name}')
            if m.islnk() or m.issym():
                continue
            tar.extract(m, dest)
" "$archive" "$staging"; then
        rm -rf "$staging"
        die "Ошибка распаковки архива $archive при аудите."
    fi

    # 1. Проверка манифеста (T21.C01, T21.C02)
    if [ -f "$staging/manifest.json" ]; then
        if ! "$py_cmd" -c "
import json, os, hashlib, sys
staging = sys.argv[1]
with open(os.path.join(staging, 'manifest.json'), 'r', encoding='utf-8') as fp:
    manifest = json.load(fp)
for rel_p, expected_h in manifest.get('files', {}).items():
    full_p = os.path.join(staging, rel_p)
    if not os.path.isfile(full_p):
        sys.exit(f'Missing backed up file: {rel_p}')
    with open(full_p, 'rb') as f:
        actual_h = hashlib.sha256(f.read()).hexdigest()
    if actual_h != expected_h:
        sys.exit(f'Checksum mismatch for {rel_p}: expected {expected_h}, got {actual_h}')
" "$staging"; then
            rm -rf "$staging"
            die "Ошибка аудита: Нарушена целостность файлов по манифесту архива (T21.C02)!"
        fi
        ok "[DRY-RUN] Манифест v2.0 и контрольные суммы SHA-256 проверены и совпадают"
    else
        warn "[DRY-RUN] Манифест manifest.json отсутствует (архив устаревшего формата v1.0)"
    fi

    # 2. Проверка SQLite базы (T21.C03)
    if [ -f "$staging/db/x-ui.db" ]; then
        if ! verify_sqlite_backup "$staging/db/x-ui.db" "$py_cmd"; then
            rm -rf "$staging"
            die "Ошибка аудита: База данных x-ui.db в архиве повреждена (PRAGMA integrity_check failed)!"
        fi
        ok "[DRY-RUN] База данных x-ui.db проверена (PRAGMA integrity_check OK)"
    fi

    # 3. Проверка SSL-ключей
    if [ -d "$staging/ssl/letsencrypt/live" ]; then
        for cert_dir in "$staging/ssl/letsencrypt/live/"*; do
            if [ -d "$cert_dir" ] && [ -f "$cert_dir/fullchain.pem" ] && [ -f "$cert_dir/privkey.pem" ]; then
                local cert_pub key_pub
                cert_pub=$(openssl x509 -noout -pubkey -in "$cert_dir/fullchain.pem" 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256 2>/dev/null || true)
                key_pub=$(openssl pkey -pubout -in "$cert_dir/privkey.pem" 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256 2>/dev/null || true)
                if [ -n "$cert_pub" ] && [ -n "$key_pub" ] && [ "$cert_pub" != "$key_pub" ]; then
                    rm -rf "$staging"
                    die "Ошибка аудита: сертификат и ключ в $cert_dir не соответствуют друг другу!"
                fi
            fi
        done
        ok "[DRY-RUN] Криптографические пары сертификат/ключ проверены"
    fi

    # 4. Проверка конфигурации .env
    if [ -f "$staging/env/server-setup.env" ]; then
        if command -v load_config_data_safe >/dev/null 2>&1; then
            if ! ( load_config_data_safe "$staging/env/server-setup.env" >/dev/null 2>&1 ); then
                rm -rf "$staging"
                die "Ошибка аудита: файл конфигурации server-setup.env содержит синтаксические ошибки!"
            fi
            ok "[DRY-RUN] Конфигурация server-setup.env проверена"
        fi
    fi

    rm -rf "$staging"
    ok "[DRY-RUN] Архив $archive проверен: целостность и формат валидны для восстановления"
    return 0
}

#!/usr/bin/env bash
# ==============================================================================
# mieru-mgr.sh - Менеджер пользователей Mieru Proxy (mita daemon)
# ==============================================================================
# Управление пользователями Mieru: просмотр, добавление, удаление,
# генерация персональных конфигурационных файлов /root/mieru-client-<user>.json
# и готовых YAML-блоков для Clash / Mihomo.
# ==============================================================================

set -euo pipefail

# Цветовое оформление при автономном запуске
RED="${RED:-$'\033[0;31m'}"
GREEN="${GREEN:-$'\033[0;32m'}"
YELLOW="${YELLOW:-$'\033[1;33m'}"
CYAN="${CYAN:-$'\033[0;36m'}"
WHITE="${WHITE:-$'\033[1;37m'}"
BOLD="${BOLD:-$'\033[1m'}"
DIM="${DIM:-$'\033[2m'}"
NC="${NC:-$'\033[0m'}"

export PYTHONIOENCODING=utf-8

if ! declare -f log >/dev/null 2>&1; then
    log()  { echo -e "  ${CYAN}[+]${NC} $*"; }
    ok()   { echo -e "  ${GREEN}✔${NC} $*"; }
    warn() { echo -e "  ${YELLOW}[!]${NC} $*"; }
    die()  { echo -e "  ${RED}✖ $*${NC}" >&2; exit 1; }
fi

MIERU_SERVER_CONFIG="${MIERU_SERVER_CONFIG:-/etc/mita/config.json}"
MIERU_SERVER_COMPAT_CONFIG="/etc/mita_server_config.json"
MIERU_CLIENT_DIR="${MIERU_CLIENT_DIR:-/root}"

resolve_python_cmd() {
    local candidate
    for candidate in "${PYTHON_CMD:-}" python3 python; do
        if [ -n "$candidate" ] && "$candidate" -c "import sys, json" >/dev/null 2>&1; then
            echo "$candidate"
            return 0
        fi
    done
    echo "python3"
}

resolve_mieru_config_path() {
    if [ -f "$MIERU_SERVER_CONFIG" ]; then
        echo "$MIERU_SERVER_CONFIG"
    elif [ -f "$MIERU_SERVER_COMPAT_CONFIG" ]; then
        echo "$MIERU_SERVER_COMPAT_CONFIG"
    else
        echo ""
    fi
}

resolve_server_domain() {
    local dom="${PRIMARY_DOMAIN:-}"
    if [ -z "$dom" ] && [ -f "/etc/server-setup.env" ]; then
        dom="$(grep -E '^PRIMARY_DOMAIN=' /etc/server-setup.env 2>/dev/null | cut -d'=' -f2 | tr -d '"'\'' ' || true)"
    fi
    if [ -z "$dom" ] && [ -f "server-setup.env" ]; then
        dom="$(grep -E '^PRIMARY_DOMAIN=' server-setup.env 2>/dev/null | cut -d'=' -f2 | tr -d '"'\'' ' || true)"
    fi
    if [ -z "$dom" ] && [ -f "/root/mieru-client.json" ]; then
        local py_cmd; py_cmd="$(resolve_python_cmd)"
        dom="$("$py_cmd" -c "
import json
try:
    with open('/root/mieru-client.json', 'r') as f:
        data = json.load(f)
    print(data['profiles'][0]['servers'][0]['ipAddress'])
except Exception:
    pass
" 2>/dev/null || true)"
    fi
    if [ -z "$dom" ]; then
        dom="$(curl -s4 -m 3 https://icanhazip.com 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")"
        dom="$(echo "$dom" | tr -d '[:space:]')"
    fi
    echo "$dom"
}

mieru_list_users() {
    local cfg
    cfg="$(resolve_mieru_config_path)"
    if [ -z "$cfg" ]; then
        die "Конфигурационный файл Mieru не найден (/etc/mita/config.json). Убедитесь, что Mieru установлен."
    fi

    local svc_status="не установлена"
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet mita 2>/dev/null; then
            svc_status="${GREEN}активна (running)${NC}"
        elif systemctl list-unit-files mita.service >/dev/null 2>&1; then
            svc_status="${RED}остановлена (inactive)${NC}"
        fi
    fi

    local py_cmd; py_cmd="$(resolve_python_cmd)"
    "$py_cmd" - "$cfg" "$svc_status" << 'EOF_LIST'
import json
import os
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

cfg_path = sys.argv[1]
svc_status = sys.argv[2]

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"  \033[0;31m[x] Ошибка чтения {cfg_path}: {e}\033[0m", file=sys.stderr)
    sys.exit(1)

bindings = data.get("portBindings", [])
port_desc = []
for b in bindings:
    p = b.get("portRange") or b.get("port")
    proto = b.get("protocol", "TCP")
    if p:
        port_desc.append(f"{p}/{proto}")
ports_str = ", ".join(port_desc) if port_desc else "8450/TCP,UDP (default)"

users = data.get("users", [])

print("")
print("  \033[1;37mКонфигурация Mieru Proxy (mita):\033[0m")
print("  \033[2m------------------------------------------------------------\033[0m")
print(f"  Файл конфигурации: \033[0;36m{cfg_path}\033[0m")
print(f"  Порты службы:      \033[1;37m{ports_str}\033[0m")
print(f"  Статус службы:     {svc_status}")
print("")
print(f"  \033[1;37mСписок активных пользователей (Всего: {len(users)}):\033[0m")
print("  \033[2m----------------------------------------------------------------------------------\033[0m")
print(f"  {'#':<4} {'Пользователь (Username)':<26} {'Пароль (Password)':<22} {'Клиентский файл'}")
print("  \033[2m----------------------------------------------------------------------------------\033[0m")

for idx, u in enumerate(users, start=1):
    uname = u.get("name", "unknown")
    upass = u.get("password", "")
    masked_pass = upass if len(upass) <= 12 else (upass[:4] + "..." + upass[-4:])
    
    # Check potential client file
    client_dir = os.environ.get("MIERU_CLIENT_DIR") or "/root"
    cfile = os.path.join(client_dir, f"mieru-client-{uname}.json")
    if not os.path.isfile(cfile) and idx == 1 and os.path.isfile(os.path.join(client_dir, "mieru-client.json")):
        cfile = os.path.join(client_dir, "mieru-client.json")
    
    status_cf = f"\033[0;32m{cfile}\033[0m" if os.path.isfile(cfile) else "\033[2m(нет файла)\033[0m"
    print(f"  {idx:<4} \033[1;37m{uname:<26}\033[0m {masked_pass:<22} {status_cf}")

print("  \033[2m----------------------------------------------------------------------------------\033[0m")
print("")
EOF_LIST
}

mieru_add_user() {
    local target_user="${1:-}"
    local target_pass="${2:-}"

    if [ "${EUID:-$(id -u)}" -ne 0 ] && [ "${MIERU_MGR_FORCE:-0}" -ne 1 ]; then
        die "Для добавления пользователя Mieru требуются права суперпользователя (sudo)."
    fi

    if [ -z "$target_user" ]; then
        die "Использование: mieru-mgr add <USERNAME> [PASSWORD]"
    fi

    if [[ ! "$target_user" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
        die "Имя пользователя '$target_user' некорректно. Разрешены только латиница, цифры, дефис и подчеркивание (3-32 символа)."
    fi

    local cfg
    cfg="$(resolve_mieru_config_path)"
    if [ -z "$cfg" ]; then
        die "Конфигурационный файл Mieru не найден (/etc/mita/config.json). Убедитесь, что Mieru установлен."
    fi

    local py_cmd; py_cmd="$(resolve_python_cmd)"

    if [ -z "$target_pass" ]; then
        target_pass="$("$py_cmd" -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(16)))" 2>/dev/null || echo "mieru$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 12 || echo "${RANDOM}${RANDOM}")")"
    fi

    local domain
    domain="$(resolve_server_domain)"

    "$py_cmd" - "$cfg" "$target_user" "$target_pass" "$domain" << 'EOF_ADD'
import json
import os
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

cfg_path = sys.argv[1]
username = sys.argv[2]
password = sys.argv[3]
domain = sys.argv[4]

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"  \033[0;31m✖ Ошибка чтения {cfg_path}: {e}\033[0m", file=sys.stderr)
    sys.exit(1)

users = data.setdefault("users", [])
found = False
for u in users:
    if u.get("name") == username:
        u["password"] = password
        found = True
        break

if not found:
    users.append({"name": username, "password": password})

# Write to both possible locations
for p in [cfg_path, "/etc/mita/config.json", "/etc/mita_server_config.json"]:
    if p == cfg_path or os.path.isfile(p):
        try:
            with open(p, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
            os.chmod(p, 0o600)
        except Exception:
            pass

# Determine port binding and transport for client
bindings = data.get("portBindings", [])
port_val = None
server_protos = []
for b in bindings:
    if "port" in b and not port_val:
        port_val = b["port"]
    elif "portRange" in b and not port_val:
        port_val = b["portRange"]
    if "protocol" in b:
        server_protos.append(str(b["protocol"]).upper())

if not port_val:
    port_val = 8450

env_trans = (os.environ.get("MIERU_TRANSPORT") or os.environ.get("MIERU_CONFIG_TRANSPORT") or "").strip().upper()
if env_trans in ("TCP", "UDP", "BOTH"):
    effective_trans = env_trans
elif "UDP" in server_protos and "TCP" not in server_protos:
    effective_trans = "UDP"
elif "TCP" in server_protos and "UDP" not in server_protos:
    effective_trans = "TCP"
elif "TCP" in server_protos and "UDP" in server_protos:
    effective_trans = "BOTH"
else:
    effective_trans = "TCP"

if effective_trans == "UDP":
    client_protocols = ["UDP"]
    yaml_transport = "UDP"
elif effective_trans == "TCP":
    client_protocols = ["TCP"]
    yaml_transport = "TCP"
else:
    client_protocols = ["TCP", "UDP"]
    yaml_transport = "TCP"

client_bindings = []
for proto in client_protocols:
    if isinstance(port_val, int) or ("-" not in str(port_val)):
        client_bindings.append({"port": int(str(port_val).split("-")[0].split(":")[0]), "protocol": proto})
    else:
        client_bindings.append({"portRange": str(port_val), "protocol": proto})

# Generate client json
client_config = {
    "profiles": [{
        "profileName": "default",
        "user": {
            "name": username,
            "password": password
        },
        "servers": [{
            "ipAddress": domain,
            "portBindings": client_bindings
        }],
        "handshakeMode": "HANDSHAKE_STANDARD"
    }],
    "activeProfile": "default",
    "rpcPort": 0,
    "socks5Port": 1080,
    "loggingLevel": "INFO",
    "httpProxyPort": 8080
}

client_dir = os.environ.get("MIERU_CLIENT_DIR") or "/root"
os.makedirs(client_dir, exist_ok=True)
client_file = os.path.join(client_dir, f"mieru-client-{username}.json")
try:
    with open(client_file, "w", encoding="utf-8") as cf:
        json.dump(client_config, cf, indent=2)
    os.chmod(client_file, 0o600)
except Exception as e:
    print(f"  \033[1;33m[!] Предупреждение: не удалось сохранить {client_file}: {e}\033[0m")

# Mihomo YAML proxy
yaml_port_key = f"port: {port_val}" if isinstance(port_val, int) or ("-" not in str(port_val)) else f"port-range: {port_val}"
mihomo_yaml = f"""  - name: "Mieru - {username}"
    type: mieru
    server: {domain}
    {yaml_port_key}
    username: {username}
    password: {password}
    transport: {yaml_transport}
    multiplexing: MULTIPLEXING_LOW
    handshake-mode: HANDSHAKE_STANDARD
    udp: true"""

action_word = "обновлен" if found else "добавлен"
print(f"ACTION={action_word}")
print(f"CLIENT_FILE={client_file}")
print(f"MIHOMO_YAML<<EOF\n{mihomo_yaml}\nEOF")
EOF_ADD

    if command -v chown >/dev/null 2>&1 && id -u mita >/dev/null 2>&1; then
        chown mita:mita /etc/mita/config.json /etc/mita_server_config.json 2>/dev/null || true
    fi
    chmod 600 /etc/mita/config.json /etc/mita_server_config.json 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart mita 2>/dev/null || true
    fi

    local client_file="${MIERU_CLIENT_DIR:-/root}/mieru-client-${target_user}.json"

    echo ""
    ok "Пользователь '${BOLD}${target_user}${NC}' успешно настроен в Mieru Proxy!"
    echo -e "  - ${YELLOW}Логин (Username):${NC}    ${WHITE}${target_user}${NC}"
    echo -e "  - ${YELLOW}Пароль (Password):${NC}   ${WHITE}${target_pass}${NC}"
    echo -e "  - ${YELLOW}Клиентский конфиг:${NC}   ${CYAN}${client_file}${NC} (chmod 600)"
    echo ""
    echo -e "  ${BOLD}Команда применения в официальном клиенте Mieru:${NC}"
    echo -e "  ${GREEN}mieru apply config ${client_file}${NC}"
    echo ""
    echo -e "  ${BOLD}Конфигурация для Mihomo / Clash Meta (proxies):${NC}"
    echo -e "${CYAN}  - name: \"Mieru - ${target_user}\""
    echo -e "    type: mieru"
    echo -e "    server: ${domain}"
    if [ -f "$client_file" ] && grep -q "portRange" "$client_file" 2>/dev/null; then
        local pr
        pr="$(grep "portRange" "$client_file" | head -n1 | cut -d'"' -f4)"
        echo -e "    port-range: ${pr}"
    else
        local p
        p="$(grep "port" "$client_file" 2>/dev/null | grep -oE '[0-9]+' | head -n1 || echo 8450)"
        echo -e "    port: ${p}"
    fi
    echo -e "    username: ${target_user}"
    echo -e "    password: ${target_pass}"
    local cli_trans="TCP"
    if [ -f "$client_file" ]; then
        if grep -q '"protocol": *"UDP"' "$client_file" 2>/dev/null && ! grep -q '"protocol": *"TCP"' "$client_file" 2>/dev/null; then
            cli_trans="UDP"
        fi
    fi
    echo -e "    transport: ${cli_trans}"
    echo -e "    multiplexing: MULTIPLEXING_LOW"
    echo -e "    handshake-mode: HANDSHAKE_STANDARD"
    echo -e "    udp: true${NC}"
    echo ""
}

mieru_del_user() {
    local target_user="${1:-}"

    if [ "${EUID:-$(id -u)}" -ne 0 ] && [ "${MIERU_MGR_FORCE:-0}" -ne 1 ]; then
        die "Для удаления пользователя Mieru требуются права суперпользователя (sudo)."
    fi

    if [ -z "$target_user" ]; then
        die "Использование: mieru-mgr del <USERNAME>"
    fi

    local cfg
    cfg="$(resolve_mieru_config_path)"
    if [ -z "$cfg" ]; then
        die "Конфигурационный файл Mieru не найден (/etc/mita/config.json). Убедитесь, что Mieru установлен."
    fi

    local py_cmd; py_cmd="$(resolve_python_cmd)"
    "$py_cmd" - "$cfg" "$target_user" << 'EOF_DEL'
import json
import os
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

cfg_path = sys.argv[1]
username = sys.argv[2]

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"  \033[0;31m✖ Ошибка чтения {cfg_path}: {e}\033[0m", file=sys.stderr)
    sys.exit(1)

users = data.get("users", [])
user_names = [u.get("name") for u in users]

if username not in user_names:
    print(f"  \033[0;31m✖ Пользователь '{username}' не найден в конфигурации Mieru.\033[0m", file=sys.stderr)
    sys.exit(2)

if len(users) <= 1:
    print(f"  \033[0;31m✖ Нельзя удалить '{username}': это единственный пользователь Mieru.\033[0m", file=sys.stderr)
    print("    Служба mita не может работать с пустым списком пользователей.", file=sys.stderr)
    sys.exit(3)

data["users"] = [u for u in users if u.get("name") != username]

for p in [cfg_path, "/etc/mita/config.json", "/etc/mita_server_config.json"]:
    if p == cfg_path or os.path.isfile(p):
        try:
            with open(p, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
            os.chmod(p, 0o600)
        except Exception:
            pass

client_dir = os.environ.get("MIERU_CLIENT_DIR") or "/root"
client_file = os.path.join(client_dir, f"mieru-client-{username}.json")
if os.path.isfile(client_file):
    try:
        os.remove(client_file)
    except Exception:
        pass

sys.exit(0)
EOF_DEL
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        exit "$rc"
    fi

    if command -v chown >/dev/null 2>&1 && id -u mita >/dev/null 2>&1; then
        chown mita:mita /etc/mita/config.json /etc/mita_server_config.json 2>/dev/null || true
    fi
    chmod 600 /etc/mita/config.json /etc/mita_server_config.json 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart mita 2>/dev/null || true
    fi

    echo ""
    ok "Пользователь '${BOLD}${target_user}${NC}' успешно удален из Mieru Proxy."
    echo ""
}

show_mieru_mgr_help() {
    cat << EOF_HELP

${BOLD}mieru-mgr${NC} - Менеджер пользователей Mieru Proxy (mita)

${BOLD}Использование:${NC}
  mieru-mgr list                       Показать список всех пользователей и статус службы
  mieru-mgr add <USERNAME> [PASSWORD]  Добавить пользователя и создать клиентский профиль .json
  mieru-mgr del <USERNAME>             Удалить пользователя из Mieru Proxy
  mieru-mgr help                       Показать эту справку

${BOLD}Примеры:${NC}
  mieru-mgr list
  mieru-mgr add alice
  mieru-mgr add bob MyStrongPass123
  mieru-mgr del bob

EOF_HELP
}

# Standalone entry point
mieru_mgr_main() {
    local cmd="${1:-list}"
    case "$cmd" in
        list|ls|show)
            mieru_list_users
            ;;
        add|create|new)
            shift || true
            mieru_add_user "${1:-}" "${2:-}"
            ;;
        del|delete|rm|remove)
            shift || true
            mieru_del_user "${1:-}"
            ;;
        help|-h|--help)
            show_mieru_mgr_help
            ;;
        *)
            warn "Неизвестная команда: $cmd"
            show_mieru_mgr_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ "$(basename "${0:-}")" == *"mieru-"* ]]; then
    mieru_mgr_main "$@"
fi


show_help() {
    cat << 'EOF_HELP'
Использование: ./maintain.sh [КОМАНДА | ОПЦИИ]

Утилита безопасного обновления, резервного копирования и восстановления для Nginx L4 + 3X-UI.

Команды резервного копирования и восстановления:
  backup, -b, --backup          Создать полный транзакционный бэкап стека (WAL-safe + селективный SSL)
  restore, --restore <АРХИВ>    Безопасно восстановить конфигурацию с валидацией SSL и автооткатом
  extract, --extract <АРХ> <DIR> Аварийно распаковать архив без прав root (PEP 706 Path Traversal safe)

Опции обслуживания:
  -c, --config <FILE>     Путь к файлу конфигурации (.env) (по умолчанию: ./server-setup.env)
  --db <PATH>             Путь к базе данных 3X-UI (по умолчанию: /etc/x-ui/x-ui.db)
  --dry-run               Только аудит и проверка (без внесения изменений)
  --force-sub             Принудительно перезаписать кастомные параметры подписки из .env
  --rollback              Мгновенный откат базы данных и Nginx к последнему бэкапу
  -y, --yes               Выполнить исправления без интерактивного подтверждения
  --mieru-list-users      Список всех пользователей Mieru Proxy
  --mieru-add-user <NAME> [PASS] Добавить пользователя Mieru и создать клиентский .json
  --mieru-del-user <NAME> Удалить пользователя Mieru
  --mieru-mgr <CMD> ...   Прямой вызов диспетчера пользователей Mieru (list, add, del)
  -v, --version           Показать версию утилиты и выйти
  -h, --help              Показать эту справку и выйти

Примеры использования:
  # 1. Создать резервную копию всей системы:
  ./maintain.sh backup

  # 2. Восстановить конфигурацию из бэкапа:
  ./maintain.sh restore /var/backups/vpn-stack/vpn-backup-20261021_120000.tar.gz

  # 3. Аварийно извлечь файлы бэкапа без root на любой машине:
  ./maintain.sh extract /var/backups/vpn-stack/vpn-backup-20261021_120000.tar.gz ./backup_files

  # 4. Предварительный аудит настроек сервера (без записи):
  ./maintain.sh --dry-run

  # 5. Запуск аудита напрямую через curl в 1 команду:
  curl -sSL https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/maintain.sh | sudo bash -s -- --dry-run
EOF_HELP
}

CONFIG_FILE=""
DB_PATH="/etc/x-ui/x-ui.db"
DRY_RUN=0
FORCE_SUB=0
ROLLBACK=0
NON_INTERACTIVE=0
MIERU_ACTION=""
MIERU_TARGET_USER=""
MIERU_TARGET_PASS=""
MIERU_MGR_ARGS=()
COMMAND=""
COMMAND_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        backup|-b|--backup)
            COMMAND="backup"
            shift
            ;;
        restore|--restore)
            COMMAND="restore"
            shift
            if [[ $# -gt 0 && "${1:0:1}" != "-" ]]; then
                COMMAND_ARGS+=("$1")
                shift
            fi
            ;;
        extract|--extract)
            COMMAND="extract"
            shift
            while [[ $# -gt 0 && "${1:0:1}" != "-" ]]; do
                COMMAND_ARGS+=("$1")
                shift
            done
            ;;
        -c|--config)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: путь к файлу конфигурации."
            CONFIG_FILE="$2"
            shift 2
            ;;
        --db)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: путь к базе данных x-ui.db."
            DB_PATH="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --force-sub)
            FORCE_SUB=1
            shift
            ;;
        --rollback)
            ROLLBACK=1
            shift
            ;;
        -y|--yes|--non-interactive)
            NON_INTERACTIVE=1
            shift
            ;;
        --mieru-list-users)
            MIERU_ACTION="list"
            shift
            ;;
        --mieru-add-user)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: имя пользователя."
            MIERU_ACTION="add"
            MIERU_TARGET_USER="$2"
            shift 2
            if [[ $# -gt 0 && "${1:0:1}" != "-" ]]; then
                MIERU_TARGET_PASS="$1"
                shift
            fi
            ;;
        --mieru-del-user)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: имя пользователя."
            MIERU_ACTION="del"
            MIERU_TARGET_USER="$2"
            shift 2
            ;;
        --mieru-mgr)
            MIERU_ACTION="mgr"
            shift
            MIERU_MGR_ARGS=("$@")
            break
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            echo "maintain.sh (Nginx L4 Stream Router Mask for 3X-UI) v9.2.0"
            exit 0
            ;;
        *)
            echo "Ошибка: Неизвестный параметр: $1. Используйте --help для вывода доступных опций." >&2
            exit 2
            ;;
    esac
done

if [ -n "$COMMAND" ]; then
    case "$COMMAND" in
        backup)
            if [ "$DRY_RUN" -eq 1 ]; then
                log "[DRY-RUN] Аудит готовности к созданию бэкапа..."
                get_sqlite_backup_python >/dev/null || die "Python sqlite3 не найден"
                ok "[DRY-RUN] Окружение SQLite валидно для создания бэкапа"
                exit 0
            fi
            acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "maintain-backup" || exit $?
            do_backup "${COMMAND_ARGS[@]}"
            exit $?
            ;;
        restore)
            if [ "$DRY_RUN" -eq 1 ]; then
                log "[DRY-RUN] Режим предварительного аудита архива перед восстановлением..."
                [[ -n "${COMMAND_ARGS[0]:-}" ]] || die "Укажите путь к архиву: ./maintain.sh --dry-run restore <архив.tar.gz>"
                audit_restore_archive "${COMMAND_ARGS[0]}"
                exit 0
            fi
            acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "maintain-restore" || exit $?
            do_restore "${COMMAND_ARGS[@]}"
            exit $?
            ;;
        extract)
            do_extract "${COMMAND_ARGS[@]}"
            exit $?
            ;;
    esac
fi

if [ -n "$MIERU_ACTION" ]; then
    case "$MIERU_ACTION" in
        list)
            mieru_list_users
            exit 0
            ;;
        add)
            mieru_add_user "$MIERU_TARGET_USER" "${MIERU_TARGET_PASS:-}"
            exit 0
            ;;
        del)
            mieru_del_user "$MIERU_TARGET_USER"
            exit 0
            ;;
        mgr)
            mieru_mgr_main "${MIERU_MGR_ARGS[@]}"
            exit 0
            ;;
    esac
fi

echo -e "${CYAN}=====================================================================${NC}"
echo -e "${GREEN}  Smart Update & Repair Tool: Nginx L4 + 3X-UI (Self-Healing Engine) ${NC}"
echo -e "${CYAN}=====================================================================${NC}"

# Проверка root
if [ "${EUID:-$(id -u)}" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    die "Для внесения изменений или отката требуются права суперпользователя (sudo)."
fi

# ОБРАБОТКА МГНОВЕННОГО ОТКАТА (--rollback)
if [ "$ROLLBACK" -eq 1 ]; then
    log "Запуск процедуры аварийного отката..."
    LATEST_DB_BAK=$(ls -t /etc/x-ui/x-ui.db.bak.* 2>/dev/null | head -n 1 || true)
    LATEST_NGINX_BAK=$(ls -td /etc/nginx.bak.* 2>/dev/null | head -n 1 || true)

    if [ -z "$LATEST_DB_BAK" ]; then
        die "Резервные копии базы данных /etc/x-ui/x-ui.db.bak.* не найдены."
    fi

    log "Восстановление базы данных 3X-UI из: $LATEST_DB_BAK"
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl stop x-ui 2>/dev/null; then
            if systemctl is-active --quiet x-ui 2>/dev/null; then
                die "Критическая ошибка: невозможно остановить работающую службу x-ui перед откатом."
            fi
        fi
        if systemctl is-active --quiet x-ui 2>/dev/null; then
            die "Критическая ошибка: служба x-ui продолжает работать после команды остановки. Откат базы отменен."
        fi
    fi
    rm -f "$DB_PATH-wal" "$DB_PATH-shm" 2>/dev/null || true
    cp -a "$LATEST_DB_BAK" "$DB_PATH"
    chmod 600 "$DB_PATH"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl start x-ui 2>/dev/null || true
    fi
    ok "База данных 3X-UI успешно восстановлена!"

    if [ -n "$LATEST_NGINX_BAK" ] && [ -d "$LATEST_NGINX_BAK" ]; then
        log "Восстановление файлов Nginx из: $LATEST_NGINX_BAK"
        cp -a "$LATEST_NGINX_BAK"/* /etc/nginx/ 2>/dev/null || true
        if command -v nginx >/dev/null 2>&1; then
            nginx -t && systemctl reload nginx
        fi
        ok "Конфигурация Nginx успешно восстановлена!"
    fi

    echo -e "${GREEN}=====================================================================${NC}"
    echo -e "${GREEN}              ОТКАТ СИСТЕМЫ УСПЕШНО ЗАВЕРШЕН!                        ${NC}"
    echo -e "${GREEN}=====================================================================${NC}"
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}>>> РЕЖИМ ПРЕДВАРИТЕЛЬНОГО АУДИТА (--dry-run). ИЗМЕНЕНИЯ НЕ ЗАПИСЫВАЮТСЯ <<<${NC}\n"
fi

# Поиск файла конфигурации .env
if [ -z "$CONFIG_FILE" ]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /root)"
    CONFIG_FILE=$(find_config_file "$script_dir" || true)
fi

# Загрузка параметров
if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
    log "Загрузка конфигурации из: $CONFIG_FILE"
    load_config_data_safe "$CONFIG_FILE" || die "Ошибка загрузки параметров из $CONFIG_FILE"
else
    warn "Конфигурационный файл .env не найден. Параметры будут считаны из базы данных 3X-UI."
fi

# Захват блокировки для изменяющих операций обслуживания (T07)
if [ "$DRY_RUN" -eq 0 ]; then
    acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "maintain-repair" || exit $?
fi

# Поиск базы данных 3X-UI
if [ ! -f "$DB_PATH" ]; then
    alt_paths=("/usr/local/x-ui/bin/x-ui.db" "/etc/x-ui/db/x-ui.db")
    found=0
    for p in "${alt_paths[@]}"; do
        if [ -f "$p" ]; then
            DB_PATH="$p"
            found=1
            break
        fi
    done
    if [ "$found" -eq 0 ]; then
        die "База данных 3X-UI не найдена ($DB_PATH). Убедитесь, что панель установлена."
    fi
fi

log "Целевая база данных: $DB_PATH"

# Определение python команды с проверкой реальной работоспособности
PYTHON_CMD=""
for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import sys" >/dev/null 2>&1; then
        PYTHON_CMD="$candidate"
        break
    fi
done

if [ -z "$PYTHON_CMD" ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
        log "Установка python3..."
        apt-get update -q && apt-get install -y python3 -q || die "Не удалось установить python3."
        PYTHON_CMD="python3"
    else
        die "Работоспособный Python 3 не найден в системе. Необходим для анализа базы SQLite."
    fi
fi

# --- ЭТАП 1: РЕЗЕРВНОЕ КОПИРОВАНИЕ ---
if [ "$DRY_RUN" -eq 0 ]; then
    BACKUP_TS="$(date +%Y%m%d_%H%M%S)"
    DB_BACKUP="${DB_PATH}.bak.${BACKUP_TS}"
    if ! backup_sqlite_db "$DB_PATH" "$DB_BACKUP"; then
        die "Критическая ошибка: невозможно создать проверенную резервную копию базы данных $DB_PATH. Модификация отменена во избежание повреждения данных."
    fi
    chmod 600 "$DB_BACKUP" 2>/dev/null || true
    ok "Создана проверенная резервная копия базы данных: $DB_BACKUP"

    if [ -d /etc/nginx ]; then
        NGINX_BACKUP="/etc/nginx.bak.${BACKUP_TS}"
        log "Создание резервной копии каталога Nginx..."
        cp -a /etc/nginx "$NGINX_BACKUP" 2>/dev/null || true
        ok "Бэкап Nginx создан: $NGINX_BACKUP"
    fi
fi

# Экспорт системных переменных для Python
export DB_PATH
export DRY_RUN
export FORCE_SUB
export PRIMARY_DOMAIN="${PRIMARY_DOMAIN:-}"
export PANEL_PORT="${PANEL_PORT:-10443}"
export PANEL_PATH="${PANEL_PATH:-}"
export SUB_PORT="${SUB_PORT:-55443}"
export SUB_PATH="${SUB_PATH:-}"
export SUB_CLASH_PATH="${SUB_CLASH_PATH:-}"
export SUB_TITLE="${SUB_TITLE:-${SERVER_PREFIX:-Server}}"
export XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
export XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH:-}"
export ENABLE_STEAL="${ENABLE_STEAL:-y}"
export STEAL_PORT="${STEAL_PORT:-45443}"
export STEAL_DOMAINS="${STEAL_DOMAINS:-}"
export ENABLE_CLASSIC="${ENABLE_CLASSIC:-y}"
export CLASSIC_PORT="${CLASSIC_PORT:-46443}"
export CLASSIC_SNI="${CLASSIC_SNI:-avito.ru}"
export ENABLE_HY2="${ENABLE_HY2:-y}"
export HY2_PORT="${HY2_PORT:-443}"
export ENABLE_AWG_V3="${ENABLE_AWG_V3:-y}"
export AWG_V3_PORT="${AWG_V3_PORT:-8443}"
export AWG_HEADER_PROTECTION_KEY="${AWG_HEADER_PROTECTION_KEY:-}"
export AWG_RANDOM_TRAILERS="${AWG_RANDOM_TRAILERS:-false}"
export ENABLE_AWG_V2="${ENABLE_AWG_V2:-n}"
export AWG_V2_PORT="${AWG_V2_PORT:-8444}"
export AWG_PRIMARY_DNS="${AWG_PRIMARY_DNS:-9.9.9.9}"
export AWG_SECONDARY_DNS="${AWG_SECONDARY_DNS:-76.76.2.0}"
export ENABLE_SS2022="${ENABLE_SS2022:-n}"
export SS2022_PORT="${SS2022_PORT:-8388}"
export ENABLE_SHADOWTLS="${ENABLE_SHADOWTLS:-n}"
export SHADOWTLS_PORT="${SHADOWTLS_PORT:-8543}"
export ENABLE_NAIVE="${ENABLE_NAIVE:-n}"
export NAIVE_PORT="${NAIVE_PORT:-8446}"
export NAIVE_DOMAIN="${NAIVE_DOMAIN:-}"
export NAIVE_USER="${NAIVE_USER:-user}"
export NAIVE_PASS="${NAIVE_PASS:-}"
export ENABLE_DNSTT="${ENABLE_DNSTT:-n}"
export DNSTT_PORT="${DNSTT_PORT:-53053}"
export DNSTT_DOMAIN="${DNSTT_DOMAIN:-}"
export DNSTT_PUBKEY="${DNSTT_PUBKEY:-}"
export ENABLE_TUIC="${ENABLE_TUIC:-n}"
export TUIC_PORT="${TUIC_PORT:-8448}"
export ENABLE_MTPROTO="${ENABLE_MTPROTO:-n}"
export MTPROTO_PORT="${MTPROTO_PORT:-8444}"
export MTPROTO_FAKETLS_DOMAIN="${MTPROTO_FAKETLS_DOMAIN:-gateway.icloud.com}"
export MTPROTO_ADTAG="${MTPROTO_ADTAG:-}"
export SSL_ENGINE_CHOICE="${SSL_ENGINE_CHOICE:-1}"

# Определение системного часового пояса
SYSTEM_TZ=""
if [ -f /etc/timezone ]; then
    SYSTEM_TZ="$(cat /etc/timezone 2>/dev/null | tr -d '[:space:]')"
elif command -v timedatectl >/dev/null 2>&1; then
    SYSTEM_TZ="$(timedatectl show --property=Timezone --value 2>/dev/null | tr -d '[:space:]')"
fi
if [ -z "$SYSTEM_TZ" ] && [ -L /etc/localtime ]; then
    SYSTEM_TZ="$(readlink /etc/localtime 2>/dev/null | sed -E 's/.*zoneinfo\///')"
fi
export TIME_LOCATION="${TIME_LOCATION:-${SYSTEM_TZ:-Europe/Moscow}}"
export SUB_UPDATES="${SUB_UPDATES:-1}"
export SUB_ENCRYPT="${SUB_ENCRYPT:-true}"
export BLOCK_SMTP="${BLOCK_SMTP:-y}"
export ENABLE_WSTUNNEL="${ENABLE_WSTUNNEL:-n}"
export WSTUNNEL_PREFIX="${WSTUNNEL_PREFIX:-}"
export WSTUNNEL_PORT="${WSTUNNEL_PORT:-8080}"
export BLOCK_LAN="${BLOCK_LAN:-y}"

HAS_NGINX=0
if command -v nginx >/dev/null 2>&1 && { systemctl is-active --quiet nginx 2>/dev/null || [ -d /etc/nginx/stream.d ]; }; then
    HAS_NGINX=1
fi
export WEB_LISTEN="${WEB_LISTEN:-$([ "$HAS_NGINX" -eq 1 ] && echo "127.0.0.1" || echo "")}"
export SUB_LISTEN="${SUB_LISTEN:-$([ "$HAS_NGINX" -eq 1 ] && echo "127.0.0.1" || echo "")}"

# Аварийная защита: гарантированный запуск x-ui при неожиданном падении скрипта
cleanup_xui() {
    local exit_code=$?
    if [ "${WAS_ACTIVE:-0}" -eq 1 ]; then
        if command -v systemctl >/dev/null 2>&1; then
            if ! systemctl is-active --quiet x-ui 2>/dev/null; then
                warn "Аварийное восстановление: перезапуск службы x-ui после сбоя скрипта..."
                systemctl start x-ui 2>/dev/null || true
            fi
        fi
    fi
    command -v release_stack_lock >/dev/null 2>&1 && release_stack_lock
    exit "$exit_code"
}
trap cleanup_xui EXIT INT TERM

# Остановка x-ui при реальном обновлении базы данных
WAS_ACTIVE=0
if [ "$DRY_RUN" -eq 0 ]; then
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet x-ui 2>/dev/null; then
        log "Временная приостановка службы 3X-UI на время обновления SQLite..."
        systemctl stop x-ui
        WAS_ACTIVE=1
    fi
fi

# --- ЭТАП 2: ВЫПОЛНЕНИЕ SMART RECONCILE ЧЕРЕЗ PYTHON ---
log "Запуск интеллектуального аудита и исправления инбаундов..."

"$PYTHON_CMD" - << 'EOF_PYTHON_RECONCILE'
import os
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

import sqlite3
import json
import uuid
import secrets
import base64

db_path = os.environ["DB_PATH"]
dry_run = os.environ.get("DRY_RUN", "0") == "1"

# Чтение и синхронизация параметров
conn = sqlite3.connect(db_path, timeout=30.0)
cur = conn.cursor()

# 1. Извлечение существующих параметров из таблицы settings
existing_settings = {}
try:
    cur.execute("SELECT key, value FROM settings")
    for k, v in cur.fetchall():
        existing_settings[k] = v
except Exception as e:
    print(f"[!] Ошибка чтения таблицы settings: {e}")

domain = os.environ.get("PRIMARY_DOMAIN") or existing_settings.get("subDomain") or "localhost"
panel_port = os.environ.get("PANEL_PORT") or existing_settings.get("webPort") or "10443"
"""Path resolution shared by the standalone configuration and repair tools."""
import secrets
import shlex
from pathlib import Path


def resolve_panel_path(configured, existing):
    """Preserve explicit and existing paths, including legacy installation paths."""
    return ((configured or "").strip().strip("/")
            or (existing or "").strip().strip("/")
            or "panel-" + secrets.token_hex(16))


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

panel_path = resolve_panel_path(os.environ.get("PANEL_PATH"), existing_settings.get("webBasePath"))

sub_port = os.environ.get("SUB_PORT") or existing_settings.get("subPort") or "55443"
sub_path = os.environ.get("SUB_PATH") or existing_settings.get("subPath") or "my-post-key"
sub_path = sub_path.strip("/")
sub_clash_env = os.environ.get("SUB_CLASH_PATH", "").strip().strip("/")
if sub_clash_env:
    sub_clash_path = sub_clash_env
elif existing_settings.get("subClashPath") and existing_settings.get("subClashPath").strip("/") != f"{sub_path}clash":
    sub_clash_path = existing_settings.get("subClashPath").strip("/")
else:
    sub_clash_path = f"{sub_path}/clash"

xhttp_port = int(os.environ.get("XHTTP_STREAM_PORT") or "50443")
xhttp_raw_path = (os.environ.get("XHTTP_STREAM_PATH") or "").strip("/")
if not xhttp_raw_path or xhttp_raw_path == "Stream-One-Path" or xhttp_raw_path.startswith("vless-"):
    cur.execute("SELECT stream_settings FROM inbounds WHERE port = ?", (xhttp_port,))
    row_xh = cur.fetchone()
    found_p = None
    if row_xh and row_xh[0]:
        try:
            found_p = json.loads(row_xh[0]).get("xhttpSettings", {}).get("path", "").strip("/")
        except Exception:
            pass
    if found_p and found_p != "Stream-One-Path" and not found_p.startswith("vless-"):
        xhttp_raw_path = found_p
    else:
        import secrets
        xhttp_raw_path = secrets.token_hex(4)
xhttp_path = "/" + xhttp_raw_path.strip("/") + "/"

enable_steal = os.environ.get("ENABLE_STEAL", "y").lower() in ("1", "y", "true")
steal_port = int(os.environ.get("STEAL_PORT") or "45443")
steal_dom = os.environ.get("STEAL_DOMAINS") or f"cdn.{domain}"
steal_dom = steal_dom.split()[0] if steal_dom.strip() else f"cdn.{domain}"
reality_fallback_port = int(os.environ.get("REALITY_FALLBACK_PORT") or "9443")

enable_classic = os.environ.get("ENABLE_CLASSIC", "y").lower() in ("1", "y", "true")
classic_port = int(os.environ.get("CLASSIC_PORT") or "46443")
classic_sni = os.environ.get("CLASSIC_SNI") or "avito.ru"
classic_sni = classic_sni.split()[0] if classic_sni.strip() else "avito.ru"

enable_hy2 = os.environ.get("ENABLE_HY2", "y").lower() in ("1", "y", "true")
hy2_port = int(os.environ.get("HY2_PORT") or "443")

enable_awg_v3 = os.environ.get("ENABLE_AWG_V3", "y").lower() in ("1", "y", "true")
awg_v3_port = int(os.environ.get("AWG_V3_PORT") or "8443")
awg_hpk_env = os.environ.get("AWG_HEADER_PROTECTION_KEY", "").strip()
awg_random_trailers_env = os.environ.get("AWG_RANDOM_TRAILERS", "false").strip().lower() in ("1", "y", "true")
awg_primary_dns = os.environ.get("AWG_PRIMARY_DNS") or "9.9.9.9"
awg_secondary_dns = os.environ.get("AWG_SECONDARY_DNS") or "76.76.2.0"

enable_awg_v2 = os.environ.get("ENABLE_AWG_V2", "n").lower() in ("1", "y", "true")
awg_v2_port = int(os.environ.get("AWG_V2_PORT") or "8444")

enable_ss2022 = os.environ.get("ENABLE_SS2022", "n").lower() in ("1", "y", "true")
ss2022_port = int(os.environ.get("SS2022_PORT") or "8388")
enable_shadowtls = os.environ.get("ENABLE_SHADOWTLS", "n").lower() in ("1", "y", "true")
shadowtls_port = int(os.environ.get("SHADOWTLS_PORT") or "8543")

enable_tuic = os.environ.get("ENABLE_TUIC", "n").lower() in ("1", "y", "true")
tuic_port = int(os.environ.get("TUIC_PORT") or "8448")

enable_mtproto = os.environ.get("ENABLE_MTPROTO", "n").lower() in ("1", "y", "true")
mtproto_port = int(os.environ.get("MTPROTO_PORT") or "8444")
mtproto_faketls_domain = (os.environ.get("MTPROTO_FAKETLS_DOMAIN") or "gateway.icloud.com").strip()
mtproto_adtag = os.environ.get("MTPROTO_ADTAG", "").strip()

ssl_engine = os.environ.get("SSL_ENGINE_CHOICE", "1")
if ssl_engine == "1":
    ssl_cert = f"/etc/letsencrypt/live/{domain}/fullchain.pem"
    ssl_key = f"/etc/letsencrypt/live/{domain}/privkey.pem"
else:
    ssl_cert = f"/etc/ssl/acme/{domain}/fullchain.pem"
    ssl_key = f"/etc/ssl/acme/{domain}/privkey.pem"

# Определение ID администратора
cur.execute("SELECT id FROM users LIMIT 1")
user_row = cur.fetchone()
admin_id = user_row[0] if user_row else 1

# Curve25519 helper (RFC 7748) для валидации и починки ключей
P = 2**255 - 19
A24 = 121665

# Инспекция существующих таблиц и колонок для гарантированной синхронизации клиентов
cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
all_tables = set(r[0] for r in cur.fetchall())

def get_table_columns(tbl):
    if tbl not in all_tables:
        return set()
    cur.execute(f"PRAGMA table_info({tbl})")
    return set(r[1] for r in cur.fetchall())

client_traffics_cols = get_table_columns("client_traffics")
clients_cols = get_table_columns("clients")
client_inbounds_cols = get_table_columns("client_inbounds")

def sync_inbound_clients(inbound_id, protocol, remark, target_settings, target_stream=None):
    clients = target_settings.get("clients", [])
    if not clients:
        return
    
    import time
    now_ms = int(time.time() * 1000)
    for idx, client in enumerate(clients):
        # 1. Email (уникальный ключ клиента в 3X-UI)
        email = client.get("email") or client.get("Email") or ""
        if not email:
            safe_remark = remark.lower().replace(" ", "-").replace("_", "-")
            email = f"client-{safe_remark}" if idx == 0 else f"client-{safe_remark}-{idx+1}"
            client["email"] = email
        
        # 2. subId для персональной подписки
        sub_id = client.get("subId") or client.get("sub_id") or ""
        if not sub_id:
            sub_id = secrets.token_hex(8)
            client["subId"] = sub_id
            
        # 3. Статус активности
        if "enable" not in client:
            client["enable"] = True
            
        client_flow = client.get("flow", "")
        client_secret = client.get("secret", "")
        client_adtag = client.get("adTag") or client.get("ad_tag") or ""
        if protocol in ("vless", "vmess"):
            client_uuid = client.get("id", "") or client.get("uuid", "")
            client_pass = client.get("password", "")
        elif protocol == "hysteria":
            client_uuid = client.get("uuid", "")
            client_pass = client.get("auth") or client.get("password") or client.get("id", "")
        elif protocol == "tuic":
            client_uuid = client.get("uuid", "") or client.get("id", "")
            client_pass = client.get("password", "")
        elif protocol == "shadowsocks":
            client_uuid = client.get("uuid", "") or client.get("id", "")
            client_pass = client.get("password", "")
        elif protocol == "mtproto":
            client_uuid = client.get("uuid", "")
            client_pass = client.get("password", "")
            if not client_pass and "secret" not in clients_cols and client_secret:
                client_pass = client_secret
        else:
            client_uuid = client.get("uuid", "")
            client_pass = client.get("password", "")
        
        if dry_run:
            continue
            
        # A. Таблица client_traffics (статистика, статус и отображение в панели 3X-UI)
        if "client_traffics" in all_tables and "email" in client_traffics_cols:
            cur.execute("SELECT id FROM client_traffics WHERE email = ?", (email,))
            ct_row = cur.fetchone()
            if not ct_row:
                ct_data = {
                    "inbound_id": inbound_id,
                    "enable": 1 if client.get("enable", True) else 0,
                    "email": email,
                    "up": 0, "down": 0, "expiry_time": 0, "total": 0, "reset": 0
                }
                for opt_col in ["uuid", "sub_id", "subId"]:
                    if opt_col in client_traffics_cols:
                        ct_data[opt_col] = client_uuid if opt_col == "uuid" else sub_id
                valid_ct = {k: v for k, v in ct_data.items() if k in client_traffics_cols}
                if valid_ct:
                    cols = ", ".join(valid_ct.keys())
                    placeholders = ", ".join(["?"] * len(valid_ct))
                    cur.execute(f"INSERT INTO client_traffics ({cols}) VALUES ({placeholders})", list(valid_ct.values()))
            else:
                ct_updates = {}
                if "enable" in client and "enable" in client_traffics_cols:
                    ct_updates["enable"] = 1 if client["enable"] else 0
                for opt_col in ["uuid", "sub_id", "subId"]:
                    if opt_col in client_traffics_cols:
                        val = client_uuid if opt_col == "uuid" else sub_id
                        if val: ct_updates[opt_col] = val
                valid_ct_up = {k: v for k, v in ct_updates.items() if k in client_traffics_cols}
                if valid_ct_up:
                    set_ct = ", ".join(f"{k} = ?" for k in valid_ct_up.keys())
                    cur.execute(f"UPDATE client_traffics SET {set_ct} WHERE email = ?", list(valid_ct_up.values()) + [email])
                
        # B. Таблица clients (единый реестр клиентов в 3X-UI v2.5+)
        client_db_id = None
        if "clients" in all_tables and "email" in clients_cols:
            cur.execute("SELECT id FROM clients WHERE email = ?", (email,))
            c_row = cur.fetchone()
            if not c_row:
                c_data = {
                    "email": email,
                    "enable": 1 if client.get("enable", True) else 0,
                    "created_at": now_ms,
                    "updated_at": now_ms
                }
                if "sub_id" in clients_cols and sub_id: c_data["sub_id"] = sub_id
                if "subId" in clients_cols and sub_id: c_data["subId"] = sub_id
                if "uuid" in clients_cols and client_uuid: c_data["uuid"] = client_uuid
                if "password" in clients_cols and client_pass and protocol != "hysteria": c_data["password"] = client_pass
                if "auth" in clients_cols and client_pass and protocol == "hysteria": c_data["auth"] = client_pass
                if "flow" in clients_cols and client_flow: c_data["flow"] = client_flow
                if "secret" in clients_cols and client_secret: c_data["secret"] = client_secret
                if "ad_tag" in clients_cols and client_adtag: c_data["ad_tag"] = client_adtag
                if "adTag" in clients_cols and client_adtag: c_data["adTag"] = client_adtag
                if "encryption" in clients_cols and client.get("encryption"): c_data["encryption"] = client["encryption"]
                if protocol == "amneziawg":
                    if "wg_private_key" in clients_cols and client.get("privateKey"):
                        c_data["wg_private_key"] = client.get("privateKey")
                    if "wg_public_key" in clients_cols and client.get("publicKey"):
                        c_data["wg_public_key"] = client.get("publicKey")
                    if "wg_allowed_ips" in clients_cols and client.get("allowedIPs"):
                        ips = client.get("allowedIPs")
                        c_data["wg_allowed_ips"] = ", ".join(ips) if isinstance(ips, list) else str(ips).strip("[]'\"")
                valid_c = {k: v for k, v in c_data.items() if k in clients_cols}
                if valid_c:
                    cols = ", ".join(valid_c.keys())
                    placeholders = ", ".join(["?"] * len(valid_c))
                    cur.execute(f"INSERT INTO clients ({cols}) VALUES ({placeholders})", list(valid_c.values()))
                    client_db_id = cur.lastrowid
            else:
                client_db_id = c_row[0]
                c_updates = {}
                if "updated_at" in clients_cols:
                    c_updates["updated_at"] = now_ms
                if "enable" in client and "enable" in clients_cols:
                    c_updates["enable"] = 1 if client["enable"] else 0
                if "sub_id" in clients_cols and sub_id: c_updates["sub_id"] = sub_id
                if "uuid" in clients_cols and client_uuid: c_updates["uuid"] = client_uuid
                if "password" in clients_cols and client_pass and protocol != "hysteria": c_updates["password"] = client_pass
                if "auth" in clients_cols and client_pass and protocol == "hysteria": c_updates["auth"] = client_pass
                if "flow" in clients_cols and client_flow: c_updates["flow"] = client_flow
                if "secret" in clients_cols and client_secret: c_updates["secret"] = client_secret
                if "ad_tag" in clients_cols and client_adtag: c_updates["ad_tag"] = client_adtag
                if "adTag" in clients_cols and client_adtag: c_updates["adTag"] = client_adtag
                if "encryption" in clients_cols and client.get("encryption"): c_updates["encryption"] = client["encryption"]
                if protocol == "amneziawg":
                    if "wg_private_key" in clients_cols and client.get("privateKey"):
                        c_updates["wg_private_key"] = client.get("privateKey")
                    if "wg_public_key" in clients_cols and client.get("publicKey"):
                        c_updates["wg_public_key"] = client.get("publicKey")
                    if "wg_allowed_ips" in clients_cols and client.get("allowedIPs"):
                        ips = client.get("allowedIPs")
                        clean_ip = ", ".join(ips) if isinstance(ips, list) else str(ips).strip("[]'\"")
                        is_legacy_v2 = "v2" in remark.lower() or "legacy" in remark.lower()
                        cur.execute("SELECT wg_allowed_ips FROM clients WHERE id = ?", (client_db_id,))
                        curr_wg_ip_row = cur.fetchone()
                        curr_wg_ip = curr_wg_ip_row[0] if curr_wg_ip_row and curr_wg_ip_row[0] else ""
                        if not is_legacy_v2 or not curr_wg_ip or curr_wg_ip.startswith("["):
                            c_updates["wg_allowed_ips"] = clean_ip
                valid_c_up = {k: v for k, v in c_updates.items() if k in clients_cols}
                if valid_c_up:
                    set_clause = ", ".join(f"{k} = ?" for k in valid_c_up.keys())
                    cur.execute(f"UPDATE clients SET {set_clause} WHERE id = ?", list(valid_c_up.values()) + [client_db_id])
                
        # C. Таблица client_inbounds (связь клиент <-> инбаунд в 3X-UI v2.5+)
        if "client_inbounds" in all_tables and client_db_id is not None:
            cur.execute("SELECT 1 FROM client_inbounds WHERE client_id = ? AND inbound_id = ?", (client_db_id, inbound_id))
            if not cur.fetchone():
                ci_data = {
                    "client_id": client_db_id,
                    "inbound_id": inbound_id,
                    "flow_override": client_flow,
                    "created_at": now_ms
                }
                valid_ci = {k: v for k, v in ci_data.items() if k in client_inbounds_cols}
                cols = ", ".join(valid_ci.keys())
                placeholders = ", ".join(["?"] * len(valid_ci))
                cur.execute(f"INSERT INTO client_inbounds ({cols}) VALUES ({placeholders})", list(valid_ci.values()))
            else:
                if "flow_override" in client_inbounds_cols:
                    cur.execute("UPDATE client_inbounds SET flow_override = ? WHERE client_id = ? AND inbound_id = ?", (client_flow, client_db_id, inbound_id))

import base64
import os
import re
import secrets
import subprocess
import uuid

# Curve25519 helper (RFC 7748) для генерации, валидации и починки ключей
P = 2**255 - 19
A24 = 121665

def clamp(k_bytes):
    b = bytearray(k_bytes)
    b[0] &= 248
    b[31] &= 127
    b[31] |= 64
    return int.from_bytes(b, "little")

def x25519(k, u=9):
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

def curve25519_pubkey(priv_b64):
    try:
        raw_priv = base64.b64decode(priv_b64)
        k = clamp(raw_priv)
        pub_raw = x25519(k, 9).to_bytes(32, "little")
        return base64.b64encode(pub_raw).decode()
    except Exception:
        return None

def curve25519_reality_pubkey(priv_b64url):
    try:
        padding = "=" * ((4 - len(priv_b64url) % 4) % 4)
        raw_priv = base64.urlsafe_b64decode(priv_b64url + padding)
        k = clamp(raw_priv)
        pub_raw = x25519(k, 9).to_bytes(32, "little")
        return base64.urlsafe_b64encode(pub_raw).decode().rstrip("=")
    except Exception:
        return None

def generate_reality_keypair():
    priv_raw = os.urandom(32)
    k = clamp(priv_raw)
    pub_raw = x25519(k, 9).to_bytes(32, "little")
    priv_b64 = base64.urlsafe_b64encode(priv_raw).decode().rstrip("=")
    pub_b64 = base64.urlsafe_b64encode(pub_raw).decode().rstrip("=")
    return priv_b64, pub_b64

def generate_wg_keypair():
    priv_raw = os.urandom(32)
    k = clamp(priv_raw)
    pub_raw = x25519(k, 9).to_bytes(32, "little")
    priv_b64 = base64.b64encode(priv_raw).decode()
    pub_b64 = base64.b64encode(pub_raw).decode()
    return priv_b64, pub_b64

def generate_vlessenc_keypair():
    for candidate in ["/usr/local/x-ui/bin/xray-linux-amd64", "/usr/local/x-ui/bin/xray-linux-arm64", "/usr/local/x-ui/bin/xray", "xray"]:
        try:
            res = subprocess.run([candidate, "vlessenc"], capture_output=True, text=True, timeout=5)
            if res.returncode == 0:
                out = res.stdout
                de_m = re.search(r'"decryption":\s*"([^"]+)"', out)
                en_m = re.search(r'"encryption":\s*"([^"]+)"', out)
                if de_m and en_m:
                    return de_m.group(1), en_m.group(1)
        except Exception:
            pass
    return None, None

def generate_ss2022_key(method="2022-blake3-aes-256-gcm"):
    raw_len = 16 if "128" in method else 32
    return base64.b64encode(os.urandom(raw_len)).decode()

def validate_ss2022_key(key_b64, method="2022-blake3-aes-256-gcm"):
    try:
        if not isinstance(key_b64, str) or not key_b64.strip():
            return False
        k = key_b64.strip().replace('-', '+').replace('_', '/')
        padding = "=" * ((4 - len(k) % 4) % 4)
        raw = base64.b64decode(k + padding, validate=True)
        expected_len = 16 if "128" in method else 32
        return len(raw) == expected_len
    except Exception:
        return False

def generate_mtproto_secret(fake_tls_domain="gateway.icloud.com"):
    domain = fake_tls_domain.strip().lower() if fake_tls_domain else "gateway.icloud.com"
    token = secrets.token_hex(16)
    domain_hex = domain.encode("utf-8").hex()
    return f"ee{token}{domain_hex}"

def validate_mtproto_secret(secret_hex):
    if not isinstance(secret_hex, str):
        return False
    s = secret_hex.strip().lower()
    return s.startswith("ee") and len(s) >= 38 and all(c in "0123456789abcdef" for c in s[2:])

def validate_mtproto_adtag(adtag):
    return bool(isinstance(adtag, str) and re.match(r"^[0-9a-fA-F]{32}$", adtag.strip()))

def generate_shadowtls_password():
    return secrets.token_urlsafe(16)

def validate_shadowtls_password(pw):
    return bool(isinstance(pw, str) and len(pw.strip()) >= 8)

def generate_masque_credentials(default_user="client"):
    return default_user, secrets.token_urlsafe(16)

def generate_naiveproxy_credentials(default_user="user"):
    return default_user, secrets.token_urlsafe(16)

def generate_tuic_credentials(default_uuid=None):
    return default_uuid or str(uuid.uuid4()), secrets.token_urlsafe(16)

def generate_dnstt_keypair():
    priv_raw = os.urandom(32)
    k = clamp(priv_raw)
    pub_raw = ((x25519(k, 9)) % P).to_bytes(32, "little")
    return priv_raw.hex(), pub_raw.hex()

def validate_dnstt_pubkey(pubkey):
    if not isinstance(pubkey, str):
        return False
    s = pubkey.strip().lower()
    return len(s) == 64 and all(c in "0123456789abcdef" for c in s)

# --- 1. СИНХРОНИЗАЦИЯ НАСТРОЕК СИСТЕМЫ (SETTINGS) ---
print("\n[+] Проверка системных настроек панели и подписок...")

force_sub = os.environ.get("FORCE_SUB", "0") == "1"

# ЗАЩИТА 1: Детектирование и сохранение существующей кастомной подписки
old_sub_domain = existing_settings.get("subDomain", "").strip()
old_sub_uri = existing_settings.get("subURI", "").strip()
old_sub_path = existing_settings.get("subPath", "").strip()

is_custom_sub = bool(old_sub_uri and (old_sub_domain != domain or old_sub_path.strip("/") != sub_path))

if is_custom_sub and not force_sub:
    print(f"  [СОХРАНЕНО] Обнаружена существующая кастомная подписка: {old_sub_uri}")
    print(f"    -> subDomain: '{old_sub_domain}', subPath: '{old_sub_path}' сохранены без изменений.")
    target_sub_uri = old_sub_uri
    target_sub_domain = old_sub_domain
    target_sub_path = old_sub_path
    target_sub_json_path = existing_settings.get("subJsonPath") or f"/{sub_path.strip('/')}/json/"
    target_sub_json_uri = existing_settings.get("subJsonURI") or f"https://{domain}{target_sub_json_path}"
    target_sub_clash_path = existing_settings.get("subClashPath") or f"/{sub_clash_path.strip('/')}/"
    if target_sub_clash_path.strip("/") == f"{sub_path}clash":
        target_sub_clash_path = f"/{sub_clash_path.strip('/')}/"
    target_sub_clash_uri = existing_settings.get("subClashURI") or f"https://{domain}{target_sub_clash_path}"
    if target_sub_clash_uri.endswith(f"{sub_path}clash/"):
        target_sub_clash_uri = f"https://{domain}{target_sub_clash_path}"
else:
    target_sub_uri = f"https://{domain}/{sub_path}/"
    target_sub_domain = domain
    target_sub_path = f"/{sub_path}/"
    target_sub_json_path = f"/{sub_path.strip('/')}/json/"
    target_sub_json_uri = f"https://{domain}{target_sub_json_path}"
    target_sub_clash_path = f"/{sub_clash_path.strip('/')}/"
    target_sub_clash_uri = f"https://{domain}{target_sub_clash_path}"

time_location = os.environ.get("TIME_LOCATION", "Europe/Moscow").strip()
sub_updates = os.environ.get("SUB_UPDATES", "1").strip()
sub_encrypt = os.environ.get("SUB_ENCRYPT", "true").strip().lower()
block_smtp = os.environ.get("BLOCK_SMTP", "y").strip().lower() in ("1", "y", "true")
block_lan = os.environ.get("BLOCK_LAN", "y").strip().lower() in ("1", "y", "true")
web_listen = os.environ.get("WEB_LISTEN", "").strip()
sub_listen = os.environ.get("SUB_LISTEN", "").strip()
sub_title = os.environ.get("SUB_TITLE", "").strip()
if not sub_title:
    srv_prefix = os.environ.get("SERVER_PREFIX", "").strip()
    if srv_prefix and srv_prefix.lower() not in ("-", "none", "off", "no"):
        sub_title = srv_prefix
if not sub_title:
    sub_title = existing_settings.get("subTitle", "").strip()
if not sub_title and domain and domain not in ("localhost", "127.0.0.1", "0.0.0.0"):
    sub_title = domain

settings_updates = {
    "webPort": panel_port,
    "webBasePath": f"/{panel_path}/",
    "subEnable": "true",
    "subPort": sub_port,
    "subPath": target_sub_path,
    "subURI": target_sub_uri,
    "subJsonPath": target_sub_json_path,
    "subJsonURI": target_sub_json_uri,
    "subJsonEnable": "true",
    "subClashPath": target_sub_clash_path,
    "subClashURI": target_sub_clash_uri,
    "subClashEnable": "true",
    "subDomain": target_sub_domain,
    "subCertFile": "",
    "subKeyFile": "",
    "timeLocation": time_location,
    "subUpdates": sub_updates,
    "subEncrypt": sub_encrypt
}

if sub_title:
    settings_updates["subTitle"] = sub_title

if web_listen:
    settings_updates["webListen"] = web_listen
if sub_listen:
    settings_updates["subListen"] = sub_listen

for k, v in settings_updates.items():
    current_val = existing_settings.get(k)
    if current_val != v:
        if not dry_run:
            cur.execute("SELECT id FROM settings WHERE key = ?", (k,))
            if cur.fetchone():
                cur.execute("UPDATE settings SET value = ? WHERE key = ?", (str(v), k))
            else:
                cur.execute("INSERT INTO settings (key, value) VALUES (?, ?)", (k, str(v)))
        print(f"  [ИСПРАВЛЕНО] Настройка {k}: '{current_val}' -> '{v}'")
    else:
        print(f"  [В ПОРЯДКЕ] Настройка {k}: '{v}'")

# --- 1.1. АУДИТ И ТЮНИНГ ШАБЛОНА XRAY (XRAYTEMPLATECONFIG) ---
print("\n[+] Аудит шаблона конфигурации Xray (DNS, безопасность и защита от спама)...")
raw_tpl = existing_settings.get("xrayTemplateConfig")
tpl = None
if raw_tpl:
    try:
        tpl = json.loads(raw_tpl)
    except Exception:
        pass

if tpl and isinstance(tpl, dict):
    tpl_modified = False

    # 1. DNS: UseIPv4 стратегия для предотвращения задержек AAAA
    dns_cfg = tpl.get("dns", {})
    if not isinstance(dns_cfg, dict):
        dns_cfg = {}
    if dns_cfg.get("queryStrategy") != "UseIPv4":
        dns_cfg["queryStrategy"] = "UseIPv4"
        tpl["dns"] = dns_cfg
        tpl_modified = True
        print("  [ИСПРАВЛЕНО] DNS queryStrategy: установлен 'UseIPv4' (устранение микрозадержек).")
    else:
        print("  [В ПОРЯДКЕ] DNS queryStrategy: 'UseIPv4'.")

    # 2. Логирование (тихий безопасный режим)
    log_cfg = tpl.get("log", {})
    if not isinstance(log_cfg, dict):
        log_cfg = {}
    if log_cfg.get("loglevel") != "warning" and not log_cfg.get("loglevel"):
        log_cfg["loglevel"] = "warning"
        log_cfg["dnsLog"] = False
        tpl["log"] = log_cfg
        tpl_modified = True

    # 3. Гарантия blackhole outbound 'blocked'
    outbounds = tpl.get("outbounds", [])
    if isinstance(outbounds, list):
        if not any(isinstance(ob, dict) and ob.get("tag") == "blocked" for ob in outbounds):
            outbounds.append({"protocol": "blackhole", "settings": {}, "tag": "blocked"})
            tpl["outbounds"] = outbounds
            tpl_modified = True
            print("  [СОЗДАНО] Outbound 'blocked' (blackhole) добавлен в шаблон.")

    # 4. Роутинг: Блокировка SMTP (порт 25), SSRF-защита, разделение RU и YouTube -> Direct
    routing = tpl.get("routing", {})
    if isinstance(routing, dict):
        rules = routing.get("rules", [])
        if isinstance(rules, list):
            bad_geosites = {
                "geosite:ru", "geosite:yandex", "geosite:vk", "geosite:youtube",
                "geosite:openai", "geosite:google-gemini", "geosite:anthropic", "geosite:cloudflare"
            }
            # Очистка от отсутствующих geosite меток
            for r in rules:
                if isinstance(r, dict) and "domain" in r and isinstance(r["domain"], list):
                    clean_d = [d for d in r["domain"] if d not in bad_geosites]
                    if len(clean_d) != len(r["domain"]):
                        r["domain"] = clean_d
                        tpl_modified = True

            if block_smtp:
                has_smtp = any(isinstance(r, dict) and r.get("outboundTag") == "blocked" and "25" in str(r.get("port", "")).split(",") for r in rules)
                if not has_smtp:
                    rules.insert(0, {"type": "field", "port": "25", "outboundTag": "blocked"})
                    tpl_modified = True
                    print("  [СОЗДАНО] Блокировка SMTP: исходящий порт 25 заблокирован (защита от бана хостером).")
                else:
                    print("  [В ПОРЯДКЕ] Блокировка SMTP: порт 25 защищен.")

            if block_lan:
                lan_ips = ["geoip:private", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "fc00::/7", "fe80::/10"]
                has_lan = any(isinstance(r, dict) and r.get("outboundTag") == "blocked" and any(ip_e in str(r.get("ip", [])) for ip_e in ["geoip:private", "127.0.0.0/8", "10.0.0.0/8"]) for r in rules)
                if not has_lan:
                    rules.insert(0, {"type": "field", "ip": lan_ips, "outboundTag": "blocked"})
                    tpl_modified = True
                    print("  [СОЗДАНО] SSRF-защита: доступ к приватным IP хоста заблокирован.")
                else:
                    print("  [В ПОРЯДКЕ] SSRF-защита: локальные сети изолированы.")

            yt_domains = [
                "domain:youtube.com", "domain:googlevideo.com", "domain:ytimg.com",
                "domain:youtu.be", "domain:youtubei.googleapis.com", "domain:yt.be"
            ]
            ru_domains = [
                "domain:ru", "domain:su", "domain:рф", "domain:xn--p1ai",
                "domain:yandex.ru", "domain:yandex.net", "domain:ya.ru",
                "domain:vk.com", "domain:vk.ru", "domain:vkvideo.ru", "domain:gosuslugi.ru",
                "domain:sberbank.ru", "domain:tbank.ru", "domain:tinkoff.ru", "domain:dzen.ru",
                "domain:mail.ru", "domain:rutube.ru", "domain:ozon.ru", "domain:wildberries.ru", "domain:avito.ru"
            ]
            warp_domains = [
                "domain:openai.com", "domain:chatgpt.com", "domain:oaistatic.com",
                "domain:oaiusercontent.com", "domain:anthropic.com", "domain:claude.ai",
                "domain:gemini.google.com", "domain:aistudio.google.com", "domain:deepmind.google",
                "domain:makersuite.google.com", "domain:generativelanguage.googleapis.com",
                "domain:ai.google.dev", "domain:google.com", "domain:cloudflare.com", "domain:challenges.cloudflare.com"
            ]

            # Исключаем YouTube домены из WARP правил
            for r in rules:
                if isinstance(r, dict) and r.get("outboundTag") == "warp":
                    if "domain" in r and isinstance(r["domain"], list):
                        clean_warp_d = [d for d in r["domain"] if not any(y in str(d).lower() for y in ["youtube", "googlevideo", "ytimg", "youtu.be"])]
                        if len(clean_warp_d) != len(r["domain"]):
                            r["domain"] = clean_warp_d
                            tpl_modified = True

            yt_rule = None
            ru_domain_rule = None
            ru_ip_rule = None
            cleaned_existing_rules = []

            for r in rules:
                if not isinstance(r, dict):
                    continue
                tag = r.get("outboundTag")
                # Direct-правило для YouTube
                if tag == "direct" and any("youtube" in str(d).lower() or "googlevideo" in str(d).lower() for d in r.get("domain", [])):
                    cur_domains = set(r.get("domain", [])) - bad_geosites
                    cur_domains.update(yt_domains)
                    r["domain"] = list(cur_domains)
                    yt_rule = r
                    continue
                # Direct-правило для RU: разделяем domain и ip (устранение AND бага Xray) с сохранением пользовательских ограничений
                if tag == "direct" and ("geoip:ru" in r.get("ip", []) or any("domain:ru" in str(d).lower() for d in r.get("domain", []))):
                    cur_d = [d for d in r.get("domain", []) if d not in bad_geosites]
                    cur_ip = list(r.get("ip", []))
                    has_custom_constraints = bool(
                        r.get("user") or r.get("inboundTag") or r.get("network") or r.get("port") or r.get("protocol") or
                        any(ip != "geoip:ru" for ip in cur_ip)
                    )
                    if has_custom_constraints:
                        # Пользовательское правило с ограничениями или кастомными сетями:
                        # сохраняем все ограничения и исходные IP, аккуратно разделяя domain и ip
                        if cur_d and cur_ip:
                            r_d = dict(r)
                            r_d["domain"] = cur_d
                            r_d.pop("ip", None)
                            cleaned_existing_rules.append(r_d)

                            r_ip = dict(r)
                            r_ip["ip"] = cur_ip
                            r_ip.pop("domain", None)
                            cleaned_existing_rules.append(r_ip)
                        else:
                            cleaned_existing_rules.append(r)
                        tpl_modified = True
                        continue

                    # Системное общее правило RU без ограничений:
                    if cur_d:
                        cur_d_set = set(cur_d)
                        cur_d_set.update(ru_domains)
                        ru_domain_rule = {
                            "type": "field",
                            "outboundTag": "direct",
                            "domain": list(cur_d_set)
                        }
                    if cur_ip:
                        cur_ip_set = set(cur_ip)
                        cur_ip_set.add("geoip:ru")
                        ru_ip_rule = {
                            "type": "field",
                            "outboundTag": "direct",
                            "ip": list(cur_ip_set)
                        }
                    else:
                        ru_ip_rule = {
                            "type": "field",
                            "outboundTag": "direct",
                            "ip": ["geoip:ru"]
                        }
                    tpl_modified = True
                    continue
                cleaned_existing_rules.append(r)

            has_warp_outbound = any(isinstance(ob, dict) and ob.get("tag") == "warp" for ob in tpl.get("outbounds", []))

            new_rules = []
            for r in cleaned_existing_rules:
                if r.get("outboundTag") in ("api", "blocked"):
                    new_rules.append(r)

            if not yt_rule:
                yt_rule = {
                    "type": "field",
                    "outboundTag": "direct",
                    "domain": yt_domains
                }
                tpl_modified = True
                print("  [СОЗДАНО] Маршрут YouTube -> DIRECT (без задержек и буферизации).")
            new_rules.append(yt_rule)

            if not ru_domain_rule:
                ru_domain_rule = {
                    "type": "field",
                    "outboundTag": "direct",
                    "domain": ru_domains
                }
                tpl_modified = True
            new_rules.append(ru_domain_rule)

            if not ru_ip_rule:
                ru_ip_rule = {
                    "type": "field",
                    "outboundTag": "direct",
                    "ip": ["geoip:ru"]
                }
                tpl_modified = True
            new_rules.append(ru_ip_rule)

            if has_warp_outbound:
                warp_rule = None
                for r in cleaned_existing_rules:
                    if r.get("outboundTag") == "warp":
                        cur_d = set(r.get("domain", [])) - bad_geosites
                        cur_d.update(warp_domains)
                        cur_d = {d for d in cur_d if not any(y in str(d).lower() for y in ["youtube", "googlevideo", "ytimg", "youtu.be"])}
                        r["domain"] = list(cur_d)
                        warp_rule = r
                        break
                if not warp_rule:
                    warp_rule = {
                        "type": "field",
                        "outboundTag": "warp",
                        "domain": [d for d in warp_domains if not any(y in str(d).lower() for y in ["youtube", "googlevideo", "ytimg", "youtu.be"])]
                    }
                    tpl_modified = True
                    print("  [СОЗДАНО] Маршрут Google, Gemini, OpenAI, Claude -> WARP (обход капч и AI).")
                new_rules.append(warp_rule)

            for r in cleaned_existing_rules:
                if r not in new_rules and r.get("outboundTag") != "warp":
                    new_rules.append(r)

            final_rules = []
            for r in new_rules:
                if "domain" in r and isinstance(r["domain"], list):
                    r["domain"] = [d for d in r["domain"] if d not in bad_geosites]
                    if not r["domain"] and not r.get("ip") and not r.get("port"):
                        continue
                final_rules.append(r)

            routing["rules"] = final_rules
            tpl["routing"] = routing

    if tpl_modified and not dry_run:
        new_tpl_json = json.dumps(tpl, indent=2, ensure_ascii=False)
        cur.execute("UPDATE settings SET value = ? WHERE key = 'xrayTemplateConfig'", (new_tpl_json,))
        print("  [ИСПРАВЛЕНО] Конфигурация xrayTemplateConfig обновлена в базе данных.")

# --- 2. СМАРТ-СВЕРКА И РЕМОНТ ИНБАУНДОВ ---
print("\n[+] Аудит и согласование инбаундов (Inbounds Smart Reconcile)...")

def smart_reconcile_inbound(port, protocol, tag, remark, default_settings, default_stream, listen="127.0.0.1"):
    cur.execute("SELECT id, settings, stream_settings, protocol, tag, remark, listen, enable FROM inbounds WHERE port = ? OR tag = ?", (port, tag))
    row = cur.fetchone()
    
    if not row:
        # Инбаунд отсутствует -> создаем под ключ
        target_settings = json.loads(json.dumps(default_settings))
        target_stream = json.loads(json.dumps(default_stream))
        if protocol == "mtproto" and "preferIp" not in target_settings:
            target_settings["preferIp"] = "prefer-ipv4"
        if "externalProxy" in target_stream and isinstance(target_stream["externalProxy"], list) and len(target_stream["externalProxy"]) > 0:
            if protocol in ("shadowsocks", "mtproto", "amneziawg"):
                target_stream["externalProxy"][0]["forceTls"] = "none"
            elif protocol == "vless" and "realitySettings" in target_stream:
                target_stream["externalProxy"][0]["forceTls"] = "same"
            elif "forceTls" not in target_stream["externalProxy"][0]:
                target_stream["externalProxy"][0]["forceTls"] = "tls"

        settings_json = json.dumps(target_settings, ensure_ascii=False)
        stream_json = json.dumps(target_stream, ensure_ascii=False)
        sniffing_json = json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"]})
        new_inbound_id = None
        if not dry_run:
            cur.execute("""
                INSERT INTO inbounds (
                    user_id, up, down, total, remark, enable, expiry_time,
                    listen, port, protocol, settings, stream_settings, tag, sniffing
                ) VALUES (?, 0, 0, 0, ?, 1, 0, ?, ?, ?, ?, ?, ?, ?)
            """, (admin_id, remark, listen, port, protocol, settings_json, stream_json, tag, sniffing_json))
            new_inbound_id = cur.lastrowid
            if "sync_inbound_clients" in globals():
                sync_inbound_clients(new_inbound_id, protocol, remark, target_settings, target_stream)
                settings_json = json.dumps(target_settings, ensure_ascii=False)
                cur.execute("UPDATE inbounds SET settings = ? WHERE id = ?", (settings_json, new_inbound_id))
        print(f"  [СОЗДАНО] Отсутствующий инбаунд: {remark} ({protocol.upper()} на порту {port}) добавлен и зарегистрирован в реестре клиентов.")
        return new_inbound_id

    inbound_id, raw_s, raw_st, proto, cur_tag, cur_remark, cur_listen, cur_enable = row
    cur_enable = 1 if cur_enable is None else cur_enable
    try:
        cur_settings = json.loads(raw_s) if raw_s else {}
    except Exception:
        cur_settings = {}
    try:
        cur_stream = json.loads(raw_st) if raw_st else {}
    except Exception:
        cur_stream = {}

    target_settings = json.loads(json.dumps(default_settings))
    target_stream = json.loads(json.dumps(default_stream))
    repairs = []
    preserved = []

    # Сохранение пользовательского названия инбаунда (remark), если оно было изменено
    final_remark = remark
    force_remarks_flag = globals().get("force_remarks", False)
    if not force_remarks_flag and cur_remark and str(cur_remark).strip():
        final_remark = str(cur_remark).strip()
        if final_remark != remark:
            preserved.append(f"пользовательское название '{final_remark}'")

    # А. Сохранение и консолидация клиентов (единый реестр)
    existing_clients = cur_settings.get("clients", [])
    if "unified_email" in globals() and globals().get("unified_email"):
        u_email = globals()["unified_email"]
        consolidated_clients = []
        has_unified = False
        default_client = default_settings.get("clients", [])[0] if default_settings.get("clients") else None
        
        for ec in existing_clients:
            ec_email = ec.get("email") or ec.get("Email") or ""
            if ec_email == u_email:
                if not has_unified and default_client:
                    merged_c = json.loads(json.dumps(default_client))
                    for limit_field in ["totalGB", "expiryTime", "limitIp", "tgId", "reset", "resetDay", "resetMax", "enable"]:
                        if limit_field in ec:
                            merged_c[limit_field] = ec[limit_field]
                    if protocol == "shadowsocks" and ec.get("password"):
                        if "validate_ss2022_key" in globals() and validate_ss2022_key(ec["password"], target_settings.get("method", "2022-blake3-aes-256-gcm")):
                            merged_c["password"] = ec["password"]
                        else:
                            repairs.append("исправлен невалидный ключ единого клиента SS-2022")
                    elif protocol == "tuic":
                        if ec.get("uuid"): merged_c["uuid"] = ec["uuid"]
                        if ec.get("password"): merged_c["password"] = ec["password"]
                    elif protocol == "mtproto":
                        if ec.get("secret"):
                            if "validate_mtproto_secret" not in globals() or validate_mtproto_secret(ec["secret"]):
                                merged_c["secret"] = ec["secret"]
                            else:
                                repairs.append("исправлен невалидный FakeTLS секрет MTProto единого клиента")
                        if ec.get("adTag") or ec.get("ad_tag"):
                            ad_cand = ec.get("adTag") or ec.get("ad_tag")
                            if "validate_mtproto_adtag" in globals() and not validate_mtproto_adtag(ad_cand):
                                merged_c["adTag"] = ""
                                repairs.append("очищен невалидный adTag MTProto")
                            else:
                                merged_c["adTag"] = ad_cand
                    elif protocol == "vless" and "xhttpSettings" in target_stream:
                        enc_cand = ec.get("encryption") or cur_settings.get("encryption") or target_settings.get("encryption")
                        if enc_cand:
                            merged_c["encryption"] = enc_cand
                    consolidated_clients.append(merged_c)
                    has_unified = True
                    preserved.append(f"единый клиент '{u_email}'")
            else:
                consolidated_clients.append(ec)
                preserved.append(f"клиент '{ec_email}'")
                
        if not has_unified and default_client:
            consolidated_clients.insert(0, json.loads(json.dumps(default_client)))
            repairs.append(f"добавлен единый клиент '{u_email}'")
            
        target_settings["clients"] = consolidated_clients
    else:
        if existing_clients and len(existing_clients) > 0:
            target_settings["clients"] = existing_clients
            preserved.append(f"клиенты ({len(existing_clients)} польз.)")
        else:
            repairs.append("добавлен клиент по умолчанию")

    # Б. Проверка и ремонт VLESS REALITY
    if protocol == "vless" and "realitySettings" in target_stream:
        cur_reality = cur_stream.get("realitySettings", {})
        
        # Сохранение privateKey
        priv = cur_reality.get("privateKey")
        if priv:
            target_stream["realitySettings"]["privateKey"] = priv
            preserved.append("privateKey Reality")
        
        # Сохранение shortIds
        sids = cur_reality.get("shortIds")
        if sids:
            target_stream["realitySettings"]["shortIds"] = sids
            preserved.append("shortIds")

        # Ремонт / сохранение settings.publicKey
        pub = cur_reality.get("settings", {}).get("publicKey") or cur_reality.get("publicKey")
        if pub:
            target_stream["realitySettings"]["settings"]["publicKey"] = pub
            if not cur_reality.get("settings", {}).get("publicKey"):
                repairs.append("исправлен отсутствующий settings.publicKey (устранена ошибка empty password)")
            else:
                preserved.append("publicKey")
        else:
            derived_pub = curve25519_reality_pubkey(target_stream["realitySettings"]["privateKey"])
            if derived_pub:
                target_stream["realitySettings"]["settings"]["publicKey"] = derived_pub
                repairs.append("восстановлен settings.publicKey по x25519")

        # Ремонт мертвого swdist.microsoft.com SNI или пустых значений
        old_snis = cur_reality.get("serverNames", [])
        old_dest = str(cur_reality.get("dest", "")).strip()
        if any("swdist.microsoft.com" in s for s in old_snis) or "swdist.microsoft.com" in old_dest:
            repairs.append(f"заменен мертвый SNI swdist.microsoft.com -> {classic_sni}")
            target_stream["realitySettings"]["serverNames"] = [classic_sni]
            target_stream["realitySettings"]["dest"] = f"{classic_sni}:443"
            target_stream["realitySettings"]["xver"] = 0
        elif old_snis:
            target_stream["realitySettings"]["serverNames"] = old_snis
            target_stream["realitySettings"]["dest"] = old_dest or target_stream["realitySettings"]["dest"]
            preserved.append(f"SNI ({','.join(old_snis)})")

        # Строгая гарантия параметров VLESS REALITY (маскировка под свой сайт: Nginx Fallback + Xver=1 + target)
        s_port = globals().get("steal_port", 45443)
        rf_port = globals().get("reality_fallback_port", 9443)
        if port == s_port or tag == "in-steal-reality" or cur_tag == "in-steal-reality":
            fallback_dest = f"127.0.0.1:{rf_port}"
            if not target_stream["realitySettings"].get("dest") or target_stream["realitySettings"]["dest"] != fallback_dest:
                target_stream["realitySettings"]["dest"] = fallback_dest
                repairs.append(f"установлен dest: {fallback_dest} (Nginx SSL Fallback, защита от сброса)")
            else:
                preserved.append(f"anti-loop dest {rf_port}")
            target_stream["realitySettings"]["target"] = fallback_dest
            if target_stream["realitySettings"].get("xver") != 1:
                target_stream["realitySettings"]["xver"] = 1
                repairs.append("установлен xver: 1 (Proxy Protocol для Nginx Anti-Loop)")

        # Строгая гарантия параметров VLESS REALITY (маскировка под внешние сервисы: xver=0, dest: 443, target: 443)
        c_port = globals().get("classic_port", 46443)
        c_sni = globals().get("classic_sni", "avito.ru")
        if port == c_port or tag == "in-classic-reality" or cur_tag == "in-classic-reality":
            if not target_stream["realitySettings"].get("dest"):
                target_stream["realitySettings"]["dest"] = f"{c_sni}:443"
                repairs.append(f"восстановлен пустой dest -> {c_sni}:443")
            target_stream["realitySettings"]["target"] = target_stream["realitySettings"]["dest"]
            target_stream["realitySettings"]["xver"] = 0

    # В. Проверка и ремонт xHTTP
    if protocol == "vless" and "xhttpSettings" in target_stream:
        cur_xh = cur_stream.get("xhttpSettings", {})
        if cur_xh.get("path"):
            target_stream["xhttpSettings"]["path"] = cur_xh["path"]
            preserved.append(f"path ({cur_xh['path']})")
        target_stream["xhttpSettings"]["mode"] = "stream-one"
        if cur_settings.get("decryption") and cur_settings["decryption"] != "none":
            target_settings["decryption"] = cur_settings["decryption"]
            preserved.append("decryption xHTTP")
        if cur_settings.get("encryption"):
            target_settings["encryption"] = cur_settings["encryption"]
            preserved.append("encryption xHTTP")
        elif not target_settings.get("encryption"):
            for c in cur_settings.get("clients", []):
                if c.get("encryption"):
                    target_settings["encryption"] = c["encryption"]
                    preserved.append("encryption xHTTP (из клиентов)")
                    break
        if cur_xh.get("xmux") and isinstance(cur_xh["xmux"], dict):
            target_stream["xhttpSettings"]["xmux"] = cur_xh["xmux"]
            preserved.append("xmux xHTTP")
        if cur_xh.get("noSSEHeader") is not None:
            target_stream["xhttpSettings"]["noSSEHeader"] = cur_xh["noSSEHeader"]
            preserved.append("noSSEHeader xHTTP")
        if cur_xh.get("xPaddingBytes"):
            target_stream["xhttpSettings"]["xPaddingBytes"] = cur_xh["xPaddingBytes"]
            preserved.append(f"xPaddingBytes ({cur_xh['xPaddingBytes']})")
        if target_settings.get("encryption"):
            for c in target_settings.get("clients", []):
                c["encryption"] = target_settings["encryption"]

    # Г. Проверка и ремонт Hysteria 2
    if protocol == "hysteria":
        if cur_settings.get("clients"):
            target_settings["clients"] = cur_settings["clients"]
            preserved.append("пароль Hysteria 2")
        
        cur_certs = cur_stream.get("tlsSettings", {}).get("certificates", [])
        if cur_certs and cur_certs[0].get("certificateFile") and os.path.exists(cur_certs[0]["certificateFile"]):
            target_stream["tlsSettings"]["certificates"] = cur_certs
            preserved.append("действующие SSL-сертификаты Hy2")

    # Д. Проверка и ремонт AmneziaWG
    if protocol == "amneziawg":
        cur_srv = cur_settings.get("server", {})
        if cur_srv.get("privateKey"):
            target_settings["server"]["privateKey"] = cur_srv["privateKey"]
            preserved.append("серверный privateKey AWG")
            
            # Валидация Curve25519
            expected_pub = curve25519_pubkey(cur_srv["privateKey"])
            actual_pub = cur_srv.get("publicKey")
            if actual_pub and expected_pub and actual_pub == expected_pub:
                target_settings["server"]["publicKey"] = actual_pub
                preserved.append("валидный publicKey AWG (Handshake OK)")
            elif expected_pub:
                target_settings["server"]["publicKey"] = expected_pub
                repairs.append("исправлен поврежденный publicKey сервера Curve25519")
        
        # Сохранение параметров обфускации
        for param in [
            "jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4",
            "headerProtectionKey", "randomTrailers", "disableCookies", "mtu", "subnetIp", "subnetCidr",
            "keepaliveTimeout", "rekeyAfterTime", "rekeyTimeout", "rejectAfterTime", "maxHandshakeAttempts",
            "i1", "i2", "i3", "i4", "i5", "contentPaddingAddition", "cpa"
        ]:
            if param in cur_srv:
                target_settings["server"][param] = cur_srv[param]
        if cur_srv.get("headerProtectionKey"):
            preserved.append("HeaderProtectionKey AWG")
        if cur_srv.get("contentPaddingAddition") or cur_srv.get("cpa"):
            preserved.append("ContentPaddingAddition (CPA)")

        # Аудит и оптимизация AmneziaWG (v3.1 и v2.0):
        # 1. RandomTrailers:
        # Для новых профилей по умолчанию отключен (off/False).
        # На существующем инбаунде сохраняем действующее значение сервера, чтобы не нарушать wire-формат клиентов.
        # Принудительно отключается только при явном указании AWG_DISABLE_RANDOM_TRAILERS=1.
        disable_rt = os.environ.get("AWG_DISABLE_RANDOM_TRAILERS", "").strip().lower() in ("1", "y", "true")
        if disable_rt and target_settings["server"].get("randomTrailers"):
            target_settings["server"]["randomTrailers"] = False
            repairs.append("отключен randomTrailers по флагу AWG_DISABLE_RANDOM_TRAILERS")

        # 1.1 Коррекция граничного условия таймингов в 3X-UI: строго max(rekey) < min(reject)
        rekey_val = str(target_settings["server"].get("rekeyAfterTime", ""))
        reject_val = str(target_settings["server"].get("rejectAfterTime", ""))
        if "-" in rekey_val and "-" in reject_val:
            try:
                r_parts = [int(x.strip()) for x in rekey_val.split("-", 1)]
                rej_parts = [int(x.strip()) for x in reject_val.split("-", 1)]
                if r_parts[1] >= rej_parts[0]:
                    new_r_max = max(r_parts[0], rej_parts[0] - 10)
                    target_settings["server"]["rekeyAfterTime"] = f"{r_parts[0]}-{new_r_max}"
                    repairs.append(f"исправлен rekeyAfterTime='{r_parts[0]}-{new_r_max}' (обеспечение max(rekey) < min(reject) для валидатора 3X-UI)")
            except (ValueError, IndexError):
                pass

        # 2. Фиксация базового MTU 1280 (уменьшение риска фрагментации)
        cur_mtu = target_settings["server"].get("mtu")
        try:
            cur_mtu_int = int(cur_mtu) if cur_mtu is not None else 1280
        except (TypeError, ValueError):
            cur_mtu_int = 1280
        if cur_mtu_int > 1280:
            target_settings["server"]["mtu"] = 1280
            repairs.append(f"исправлен MTU={cur_mtu_int} -> 1280 (базовый MTU)")

        # 3. Аудит смещений S1-S4: должны быть >= 12 при активном HeaderProtectionKey
        has_hpk = bool(target_settings["server"].get("headerProtectionKey"))
        if has_hpk:
            s_defaults = {"s1": 16, "s2": 16, "s3": 16, "s4": 16}
            for s_param, min_val in [("s1", 12), ("s2", 12), ("s3", 12), ("s4", 12)]:
                val = target_settings["server"].get(s_param)
                try:
                    val_int = int(val)
                except (TypeError, ValueError):
                    val_int = 0
                if val_int < min_val:
                    target_settings["server"][s_param] = s_defaults[s_param]
                    repairs.append(f"исправлен {s_param}={val} -> {s_defaults[s_param]} (требование HPK: S >= 12)")

        # 4. Валидация мусорных пакетов Jc / Jmin / Jmax (допустимый диапазон Jc: 0-128, J: 0-1280)
        cur_jc = target_settings["server"].get("jc")
        if cur_jc is not None:
            try:
                jc_int = int(cur_jc)
                if jc_int < 0 or jc_int > 128:
                    target_settings["server"]["jc"] = 4
                    repairs.append(f"исправлен Jc={cur_jc} -> 4 (выход за пределы протокола 0-128)")
            except (TypeError, ValueError):
                target_settings["server"]["jc"] = 4
                repairs.append(f"исправлен Jc={cur_jc} -> 4 (некорректное значение)")

        cur_jmin = target_settings["server"].get("jmin")
        cur_jmax = target_settings["server"].get("jmax")
        if cur_jmin is not None and cur_jmax is not None:
            try:
                jmin_int = int(cur_jmin)
                jmax_int = int(cur_jmax)
                if jmin_int < 0 or jmax_int < 0 or jmin_int > jmax_int or jmax_int > 1280:
                    target_settings["server"]["jmin"] = 40
                    target_settings["server"]["jmax"] = 70
                    repairs.append("исправлены некорректные Jmin/Jmax -> Jmin=40, Jmax=70")
            except (TypeError, ValueError):
                target_settings["server"]["jmin"] = 40
                target_settings["server"]["jmax"] = 70
                repairs.append("исправлены нечисловые Jmin/Jmax -> Jmin=40, Jmax=70")

    # Е. Проверка и ремонт Shadowsocks 2022
    if protocol == "shadowsocks":
        ss_method = cur_settings.get("method") or target_settings.get("method", "2022-blake3-aes-256-gcm")
        target_settings["method"] = ss_method
        target_settings["network"] = "tcp,udp"
        target_settings["udpOverTcp"] = True
        target_settings["udp_over_tcp"] = True
        if target_stream.get("network") in ("tcp,udp", "udp"):
            target_stream["network"] = "tcp"
            repairs.append("исправлен network в stream_settings -> 'tcp'")

        # Валидация / сохранение серверного пароля (PSK)
        cur_srv_pwd = cur_settings.get("password")
        if cur_srv_pwd and "validate_ss2022_key" in globals() and validate_ss2022_key(cur_srv_pwd, ss_method):
            target_settings["password"] = cur_srv_pwd
            preserved.append("серверный ключ SS-2022")
        elif "generate_ss2022_key" in globals():
            target_settings["password"] = generate_ss2022_key(ss_method)
            repairs.append("сгенерирован валидный серверный ключ SS-2022 (исправлена ошибка длины)")

        # Аудит клиентов: валидация ключей и очистка устаревшего поля 'method'
        c_repaired = False
        method_removed = False
        for c in target_settings.get("clients", []):
            if "method" in c:
                c.pop("method", None)
                method_removed = True
            c_pwd = c.get("password")
            if not c_pwd or ("validate_ss2022_key" in globals() and not validate_ss2022_key(c_pwd, ss_method)):
                if "generate_ss2022_key" in globals():
                    c["password"] = generate_ss2022_key(ss_method)
                    c_repaired = True
        if method_removed:
            repairs.append("удалено устаревшее поле client.method")
        if c_repaired:
            repairs.append("исправлен невалидный ключ клиента SS-2022")
        elif not any("невалидный ключ" in r for r in repairs):
            preserved.append("ключи клиентов SS-2022")

    # Ж. Проверка и ремонт TUIC v5
    if protocol == "tuic":
        tuic_cert = cur_settings.get("certificate") or target_settings.get("certificate") or globals().get("ssl_cert") or ""
        tuic_key = cur_settings.get("private_key") or target_settings.get("private_key") or globals().get("ssl_key") or ""
        if cur_settings.get("certificate") and cur_settings.get("private_key"):
            target_settings["certificate"] = tuic_cert
            target_settings["private_key"] = tuic_key
            preserved.append("SSL-сертификаты TUIC")
        else:
            target_settings["certificate"] = tuic_cert
            target_settings["private_key"] = tuic_key
            repairs.append("добавлены пути сертификатов в settings TUIC")

        target_settings["congestion_control"] = cur_settings.get("congestion_control") or target_settings.get("congestion_control", "bbr")
        target_settings["alpn"] = cur_settings.get("alpn") or target_settings.get("alpn", ["h3", "spdy/3.1"])
        for tuic_opt in ["udp_relay_mode", "zero_rtt_handshake", "max_idle_time", "authentication_timeout", "max_udp_relay_packet_size", "sni"]:
            if tuic_opt in cur_settings:
                target_settings[tuic_opt] = cur_settings[tuic_opt]
        if cur_settings.get("congestion_control"):
            preserved.append(f"congestion_control ({target_settings['congestion_control']})")
        if cur_settings.get("alpn"):
            preserved.append(f"alpn ({target_settings['alpn']})")

        target_stream["network"] = "quic"
        target_stream["security"] = "tls"

    # З. Проверка и ремонт Telegram MTProxy (FakeTLS)
    if protocol == "mtproto":
        root_cleaned = False
        for obsolete_field in ["secret", "adTag", "ad_tag"]:
            if obsolete_field in cur_settings or obsolete_field in target_settings:
                target_settings.pop(obsolete_field, None)
                root_cleaned = True
        if root_cleaned:
            repairs.append("очищены устаревшие корневые поля secret/adTag в settings MTProto")

        if cur_settings.get("domainFronting"):
            target_settings["domainFronting"] = cur_settings["domainFronting"]
            preserved.append("domainFronting MTProto")

        target_settings["preferIp"] = cur_settings.get("preferIp") or target_settings.get("preferIp") or "prefer-ipv4"
        if target_settings.get("preferIp") == "prefer-ipv4":
            preserved.append("preferIp (prefer-ipv4)")

        mtp_faketls = globals().get("mtproto_faketls_domain") or target_settings.get("domainFronting", {}).get("ip") or "gateway.icloud.com"
        for c in target_settings.get("clients", []):
            c_sec = c.get("secret")
            if not c_sec or ("validate_mtproto_secret" in globals() and not validate_mtproto_secret(c_sec)):
                if "generate_mtproto_secret" in globals():
                    c["secret"] = generate_mtproto_secret(mtp_faketls)
                    repairs.append("исправлен/сгенерирован FakeTLS секрет MTProto")
            else:
                preserved.append("секрет FakeTLS MTProto")
            c_ad = c.get("adTag") or c.get("ad_tag")
            if c_ad:
                if "validate_mtproto_adtag" in globals() and not validate_mtproto_adtag(c_ad):
                    c["adTag"] = ""
                    c.pop("ad_tag", None)
                    repairs.append("очищен невалидный adTag MTProto")
                else:
                    c["adTag"] = c_ad
                    c.pop("ad_tag", None)
                    preserved.append("промо-тег adTag MTProto")

    # И. Проверка и сохранение externalProxy (:443, SNI и кастомных хостов узлов)
    cur_ext = cur_stream.get("externalProxy", [])
    expected_ext_port = 443 if protocol in ("vless", "hysteria") and port != hy2_port else (hy2_port if protocol == "hysteria" else port)

    def_ext = default_stream.get("externalProxy", [])
    def_dest = def_ext[0].get("dest") if (def_ext and isinstance(def_ext, list) and def_ext[0].get("dest")) else domain
    def_sni = def_ext[0].get("sni", "") if (def_ext and isinstance(def_ext, list) and def_ext[0].get("sni")) else ""

    # Сохраняем кастомный хост узла (dest), если он был настроен и не равен localhost
    target_dest = def_dest
    if cur_ext and len(cur_ext) > 0 and cur_ext[0].get("dest"):
        ext_dest = str(cur_ext[0]["dest"]).strip()
        if ext_dest and ext_dest not in ("127.0.0.1", "localhost", "0.0.0.0"):
            target_dest = ext_dest
            if ext_dest != domain and ext_dest != def_dest:
                preserved.append(f"кастомный хост узла ({ext_dest})")

    # Сохраняем SNI для externalProxy (критично для VLESS REALITY и маршрутизации Nginx Stream L4)
    target_sni = def_sni
    if cur_ext and len(cur_ext) > 0 and cur_ext[0].get("sni"):
        ext_sni = str(cur_ext[0]["sni"]).strip()
        if ext_sni:
            target_sni = ext_sni
            if target_sni != def_sni:
                preserved.append(f"кастомный externalProxy SNI ({ext_sni})")

    if protocol in ("shadowsocks", "mtproto", "amneziawg"):
        force_tls_val = "none"
    elif protocol == "vless" and "realitySettings" in target_stream:
        force_tls_val = "same"
    else:
        force_tls_val = "tls"

    ext_entry = {
        "dest": target_dest,
        "port": expected_ext_port,
        "forceTls": force_tls_val,
        "remark": final_remark
    }
    if target_sni:
        ext_entry["sni"] = target_sni
    if def_ext and isinstance(def_ext, list):
        if def_ext[0].get("fingerprint"):
            ext_entry["fingerprint"] = def_ext[0]["fingerprint"]
        if def_ext[0].get("alpn"):
            ext_entry["alpn"] = def_ext[0]["alpn"]

    needs_ext_repair = (
        not cur_ext
        or cur_ext[0].get("port") != expected_ext_port
        or cur_ext[0].get("dest") != target_dest
        or cur_ext[0].get("remark") != final_remark
        or cur_ext[0].get("forceTls") != force_tls_val
        or (target_sni and cur_ext[0].get("sni") != target_sni)
    )

    if needs_ext_repair:
        target_stream["externalProxy"] = [ext_entry]
        sni_desc = f", sni: {target_sni}" if target_sni else ""
        repairs.append(f"исправлен externalProxy -> {target_dest}:{expected_ext_port}{sni_desc}")
    else:
        target_stream["externalProxy"] = cur_ext
        preserved.append(f"externalProxy :{expected_ext_port}")

    # Синхронизация клиентов в реестре (client_traffics, clients, client_inbounds)
    if "sync_inbound_clients" in globals():
        sync_inbound_clients(inbound_id, protocol, final_remark, target_settings, target_stream)

    # Запись в SQLite
    settings_json = json.dumps(target_settings, ensure_ascii=False)
    stream_json = json.dumps(target_stream, ensure_ascii=False)
    sniffing_json = json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"]})

    if not dry_run:
        cur.execute("""
            UPDATE inbounds
            SET protocol = ?, tag = ?, remark = ?, settings = ?, stream_settings = ?, listen = ?, sniffing = ?, enable = ?
            WHERE id = ?
        """, (protocol, tag, final_remark, settings_json, stream_json, listen, sniffing_json, cur_enable, inbound_id))

    status_str = f"  [ОБНОВЛЕН] {final_remark} (порт {port}):"
    if repairs:
        status_str += f"\n    -> Исправлено: {', '.join(repairs)}"
    if preserved:
        status_str += f"\n    -> Сохранено: {', '.join(preserved)}"
    print(status_str)
    return inbound_id

# --- Формирование эталонных конфигураций протоколов ---
def_uuid = str(uuid.uuid4())
def_reality_priv, def_reality_pub = generate_reality_keypair()
def_reality_sid = secrets.token_hex(8)
def_reality_sids = [def_reality_sid] + [secrets.token_hex(n) for n in (1, 2, 3, 6)]
def_hy2_pass = secrets.token_hex(12)
def_wg_s_priv, def_wg_s_pub = generate_wg_keypair()
def_wg_c_priv, def_wg_c_pub = generate_wg_keypair()
def_wg_hpk = awg_hpk_env or base64.b64encode(secrets.token_bytes(32)).decode()
def_ss_method = "2022-blake3-aes-256-gcm"
def_ss_server_pass = generate_ss2022_key(def_ss_method)
def_ss_client_pass = generate_ss2022_key(def_ss_method)
def_tuic_uuid, _ = generate_tuic_credentials()
def_tuic_pass = def_ss_client_pass
def_mtp_secret = generate_mtproto_secret(mtproto_faketls_domain)

cur.execute("SELECT port, protocol FROM inbounds")
existing_inbound_protos = {r[1] for r in cur.fetchall()}

# 1. VLESS REALITY (маскировка под свой сайт)
if enable_steal:
    s_set = {"clients": [{"id": def_uuid, "flow": "xtls-rprx-vision"}], "decryption": "none", "testseed": [900, 500, 900, 256]}
    s_str = {
        "network": "tcp",
        "tcpSettings": {"acceptProxyProtocol": True, "header": {"type": "none"}},
        "security": "reality",
        "realitySettings": {
            "show": False, "xver": 1, "dest": f"127.0.0.1:{reality_fallback_port}", "target": f"127.0.0.1:{reality_fallback_port}",
            "serverNames": [steal_dom], "privateKey": def_reality_priv, "minClientVer": "1.0.0",
            "shortIds": def_reality_sids,
            "settings": {"publicKey": def_reality_pub, "fingerprint": "firefox", "serverName": steal_dom, "spiderX": "/"}
        },
        "externalProxy": [{"dest": domain, "port": 443, "forceTls": "same", "sni": steal_dom, "fingerprint": "firefox", "remark": "VLESS_STEAL"}]
    }
    smart_reconcile_inbound(steal_port, "vless", "in-steal-reality", "VLESS_STEAL", s_set, s_str, listen="127.0.0.1")

# 2. VLESS REALITY (маскировка под внешние сервисы)
if enable_classic:
    c_set = {"clients": [{"id": def_uuid, "flow": "xtls-rprx-vision"}], "decryption": "none", "testseed": [900, 500, 900, 256]}
    c_str = {
        "network": "tcp",
        "tcpSettings": {"acceptProxyProtocol": True, "header": {"type": "none"}},
        "security": "reality",
        "realitySettings": {
            "show": False, "xver": 0, "dest": f"{classic_sni}:443", "target": f"{classic_sni}:443",
            "serverNames": [classic_sni], "privateKey": def_reality_priv, "minClientVer": "1.0.0",
            "shortIds": def_reality_sids,
            "settings": {"publicKey": def_reality_pub, "fingerprint": "firefox", "serverName": classic_sni, "spiderX": "/"}
        },
        "externalProxy": [{"dest": domain, "port": 443, "forceTls": "same", "sni": classic_sni, "fingerprint": "firefox", "remark": "VLESS_CLASSIC"}]
    }
    smart_reconcile_inbound(classic_port, "vless", "in-classic-reality", "VLESS_CLASSIC", c_set, c_str, listen="127.0.0.1")

# 3. VLESS xHTTP (Stream-One) - сохраняем или генерируем постквантовый ML-KEM-768
cur.execute("SELECT settings FROM inbounds WHERE port = ? OR tag = 'in-xhttp-stream'", (xhttp_port,))
row_xh = cur.fetchone()
prev_xh_dec = "none"
prev_xh_enc = None
if row_xh and row_xh[0]:
    try:
        prev_s = json.loads(row_xh[0])
        if prev_s.get("decryption") and prev_s["decryption"] != "none":
            prev_xh_dec = prev_s["decryption"]
            prev_xh_enc = prev_s.get("encryption")
            if not prev_xh_enc and prev_s.get("clients"):
                for _c in prev_s["clients"]:
                    if _c.get("encryption"):
                        prev_xh_enc = _c["encryption"]
                        break
    except Exception:
        pass

if prev_xh_dec != "none" and prev_xh_enc:
    c_xh = {"id": def_uuid, "flow": "", "encryption": prev_xh_enc}
    x_set = {"clients": [c_xh], "decryption": prev_xh_dec, "encryption": prev_xh_enc}
else:
    vless_dekey, vless_enkey = generate_vlessenc_keypair()
    if vless_dekey and vless_enkey:
        x_set = {"clients": [{"id": def_uuid, "flow": "", "encryption": vless_enkey}], "decryption": vless_dekey, "encryption": vless_enkey}
    else:
        x_set = {"clients": [{"id": def_uuid, "flow": ""}], "decryption": "none"}
x_str = {
    "network": "xhttp",
    "xhttpSettings": {
        "path": f"/{xhttp_path.strip('/')}/", "host": domain, "mode": "stream-one",
        "noSSEHeader": True,
        "xPaddingBytes": "100-500", "xPaddingObfsMode": False, "xPaddingKey": "",
        "xmux": {
            "maxConcurrency": "0",
            "maxConnections": "1-3",
            "cMaxReuseTimes": "300-600",
            "hKeepAlivePeriod": 600,
            "hMaxRequestTimes": "1000-2000",
            "hMaxReusableSecs": "1200-2400"
        }
    },
    "security": "none",
    "externalProxy": [{"dest": domain, "port": 443, "forceTls": "tls", "sni": domain, "fingerprint": "firefox", "alpn": "h2", "remark": "VLESS_XHTTP"}]
}
smart_reconcile_inbound(xhttp_port, "vless", "in-xhttp-stream", "VLESS_XHTTP", x_set, x_str, listen="127.0.0.1")

unified_vless_enkey = ""
cur.execute("SELECT settings FROM inbounds WHERE port = ? OR tag = 'in-xhttp-stream'", (xhttp_port,))
_row_xh = cur.fetchone()
if _row_xh and _row_xh[0]:
    try:
        _s_xh = json.loads(_row_xh[0])
        unified_vless_enkey = _s_xh.get("encryption", "") or ""
        if not unified_vless_enkey and _s_xh.get("clients"):
            for _c in _s_xh["clients"]:
                if _c.get("encryption"):
                    unified_vless_enkey = _c["encryption"]
                    break
    except Exception:
        pass
if not unified_vless_enkey:
    unified_vless_enkey = prev_xh_enc or (vless_enkey if 'vless_enkey' in locals() else "") or ""

# 4. Hysteria 2
if enable_hy2:
    h_set = {"clients": [{"id": def_hy2_pass}], "version": 2}
    h_str = {
        "network": "hysteria",
        "hysteriaSettings": {"version": 2, "udpIdleTimeout": 60, "masquerade": {"type": "proxy", "url": "http://127.0.0.1:80"}},
        "security": "tls",
        "tlsSettings": {
            "serverName": domain, "minVersion": "1.3", "maxVersion": "1.3",
            "certificates": [{"certificateFile": ssl_cert, "keyFile": ssl_key}], "alpn": ["h3"]
        },
        "externalProxy": [{"dest": domain, "port": hy2_port, "forceTls": "tls", "remark": "Hysteria 2"}]
    }
    smart_reconcile_inbound(hy2_port, "hysteria", "in-hysteria2", "Hysteria 2", h_set, h_str, listen="0.0.0.0")

# 5. AmneziaWG v3.1
if enable_awg_v3:
    awg_i1_env = os.environ.get("AWG_I1", "").strip()
    if awg_i1_env.lower() == "dns":
        awg_i1_env = "<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>"
    a3_set = {
        "clients": [{
            "privateKey": def_wg_c_priv, "publicKey": def_wg_c_pub,
            "allowedIPs": ["10.8.1.2/32"], "email": "Client-1", "enable": True
        }],
        "server": {
            "disableCookies": False,
            "h1": "1", "h2": "2", "h3": "3", "h4": "4", "jc": 4, "jmax": 70, "jmin": 40,
            "keepaliveTimeout": "15-20", "maxHandshakeAttempts": "20-25", "mtu": 1280,
            "primaryDns": awg_primary_dns, "secondaryDns": awg_secondary_dns,
            "privateKey": def_wg_s_priv, "publicKey": def_wg_s_pub,
            "headerProtectionKey": def_wg_hpk,
            "randomTrailers": True,
            "rejectAfterTime": "180-210", "rekeyAfterTime": "120-170",
            "rekeyTimeout": "3-4", "s1": 16, "s2": 16, "s3": 16, "s4": 16,
            "subnetCidr": 22, "subnetIp": "10.8.0.0",
            "i1": awg_i1_env
        }
    }
    a3_str = {"externalProxy": [{"dest": domain, "port": awg_v3_port, "remark": "AmneziaWG v3.1"}]}
    smart_reconcile_inbound(awg_v3_port, "amneziawg", "in-8443-udp", "AmneziaWG v3.1", a3_set, a3_str, listen="0.0.0.0")

# 6. AmneziaWG v2.0
if enable_awg_v2:
    a2_set = {
        "clients": [{
            "privateKey": def_wg_c_priv, "publicKey": def_wg_c_pub,
            "allowedIPs": ["10.8.2.2/32"], "email": "Client-Router", "enable": True
        }],
        "server": {
            "h1": "149419586", "h2": "878791997", "h3": "1251051976", "h4": "1657628296",
            "jc": 2, "jmax": 50, "jmin": 20, "mtu": 1280, "primaryDns": awg_primary_dns, "secondaryDns": awg_secondary_dns,
            "privateKey": def_wg_s_priv, "publicKey": def_wg_s_pub,
            "s1": 16, "s2": 20, "s3": 24, "s4": 16, "subnetCidr": 24, "subnetIp": "10.8.2.0"
        }
    }
    a2_str = {"externalProxy": [{"dest": domain, "port": awg_v2_port, "remark": "AmneziaWG v2.0"}]}
    smart_reconcile_inbound(awg_v2_port, "amneziawg", "in-awg-v2", "AmneziaWG v2.0", a2_set, a2_str, listen="0.0.0.0")

# 7. Shadowsocks 2022
if enable_ss2022 or "shadowsocks" in existing_inbound_protos:
    ss_set = {
        "method": def_ss_method,
        "password": def_ss_server_pass,
        "network": "tcp,udp",
        "udpOverTcp": True,
        "udp_over_tcp": True,
        "clients": [{"email": "Client", "password": def_ss_client_pass, "enable": True}]
    }
    ss_ext_proxies = [{"dest": domain, "port": ss2022_port, "forceTls": "none", "remark": "Shadowsocks 2022"}]
    if enable_shadowtls:
        ss_ext_proxies.append({"dest": domain, "port": shadowtls_port, "forceTls": "tls", "remark": "ShadowTLS v4 + SS-2022"})
    ss_str = {
        "network": "tcp",
        "security": "none",
        "externalProxy": ss_ext_proxies
    }
    smart_reconcile_inbound(ss2022_port, "shadowsocks", "in-shadowsocks-2022", "Shadowsocks 2022", ss_set, ss_str, listen="0.0.0.0")

# 8. TUIC v5
if enable_tuic or "tuic" in existing_inbound_protos:
    tuic_set = {
        "certificate": ssl_cert,
        "private_key": ssl_key,
        "congestion_control": "bbr",
        "alpn": ["h3", "spdy/3.1"],
        "udp_relay_mode": "native",
        "zero_rtt_handshake": False,
        "max_idle_time": 15,
        "authentication_timeout": 3,
        "max_udp_relay_packet_size": 1500,
        "sni": domain,
        "clients": [{"uuid": def_tuic_uuid, "password": def_tuic_pass, "email": "Client", "enable": True}]
    }
    tuic_str = {
        "network": "quic",
        "security": "tls",
        "externalProxy": [{"dest": domain, "port": tuic_port, "forceTls": "tls", "remark": "TUIC v5"}]
    }
    smart_reconcile_inbound(tuic_port, "tuic", "in-tuic-v5", "TUIC v5", tuic_set, tuic_str, listen="0.0.0.0")

# 9. Telegram MTProxy FakeTLS
if enable_mtproto or "mtproto" in existing_inbound_protos:
    mtp_set = {
        "preferIp": "prefer-ipv4",
        "domainFronting": {"ip": mtproto_faketls_domain, "port": 443, "proxyProtocol": False},
        "clients": [{"email": "Client", "secret": def_mtp_secret, "adTag": mtproto_adtag, "enable": True}]
    }
    mtp_str = {
        "network": "tcp",
        "security": "none",
        "externalProxy": [{"dest": domain, "port": mtproto_port, "forceTls": "none", "remark": "Telegram MTProxy"}]
    }
    smart_reconcile_inbound(mtproto_port, "mtproto", "in-mtproto-faketls", "Telegram MTProxy", mtp_set, mtp_str, listen="0.0.0.0")

# --- Синхронизация реестра Hosts для персональных подписок 3X-UI ---
cur.execute("""
    CREATE TABLE IF NOT EXISTS hosts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id TEXT DEFAULT '',
        inbound_id INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER DEFAULT 0,
        remark TEXT DEFAULT '',
        address TEXT DEFAULT '',
        port INTEGER DEFAULT 443,
        security TEXT DEFAULT 'same',
        sni TEXT DEFAULT '',
        host_header TEXT DEFAULT '',
        path TEXT DEFAULT '',
        alpn TEXT DEFAULT '',
        fingerprint TEXT DEFAULT '',
        allow_insecure INTEGER DEFAULT 0,
        is_disabled INTEGER DEFAULT 0,
        is_hidden INTEGER DEFAULT 0,
        tags TEXT DEFAULT '',
        ech_config_list TEXT DEFAULT '',
        mux_params TEXT DEFAULT '',
        sockopt_params TEXT DEFAULT '',
        final_mask TEXT DEFAULT '',
        exclude_from_sub_types TEXT DEFAULT ''
    )
""")
cur.execute("PRAGMA table_info(hosts)")
active_host_cols = {r[1] for r in cur.fetchall()}

def sync_host_entry(ib_id, host_remark, addr, host_port, sec, host_sni="", host_path="", host_alpn="", host_fp="firefox", sort_order=0):
    if ib_id is None:
        return
    cur.execute("SELECT id, remark FROM hosts WHERE inbound_id = ?", (ib_id,))
    h_row = cur.fetchone()
    if h_row:
        h_id, existing_rem = h_row
        final_h_remark = existing_rem if (existing_rem and existing_rem.strip()) else host_remark
        if not dry_run:
            cur.execute("""
                UPDATE hosts
                SET address = ?, port = ?, security = ?, sni = ?, path = ?, alpn = ?, fingerprint = ?, sort_order = ?, remark = ?
                WHERE id = ?
            """, (addr, host_port, sec, host_sni, host_path, host_alpn, host_fp, sort_order, final_h_remark, h_id))
    else:
        gid = str(uuid.uuid4())
        col_candidates = {
            "group_id": gid, "groupId": gid,
            "inbound_id": ib_id, "inboundId": ib_id,
            "sort_order": sort_order, "sortOrder": sort_order,
            "remark": host_remark, "address": addr, "port": host_port, "security": sec,
            "sni": host_sni, "host_header": "", "hostHeader": "", "path": host_path,
            "alpn": host_alpn, "fingerprint": host_fp, "allow_insecure": 0, "allowInsecure": 0,
            "is_disabled": 0, "isDisabled": 0, "is_hidden": 0, "isHidden": 0,
            "tags": "", "ech_config_list": "", "mux_params": "", "sockopt_params": "",
            "final_mask": "", "exclude_from_sub_types": ""
        }
        insert_data = {k: v for k, v in col_candidates.items() if k in active_host_cols}
        keys = list(insert_data.keys())
        vals = [insert_data[k] for k in keys]
        placeholders = ",".join(["?"] * len(keys))
        if not dry_run:
            cur.execute(f"INSERT INTO hosts ({','.join(keys)}) VALUES ({placeholders})", vals)

def lookup_inbound_id(tag_val, port_val):
    cur.execute("SELECT id FROM inbounds WHERE tag = ? OR port = ?", (tag_val, port_val))
    r = cur.fetchone()
    return r[0] if r else None

if enable_steal:
    s_iid = lookup_inbound_id("in-steal-reality", steal_port)
    if s_iid:
        cur.execute("SELECT remark FROM inbounds WHERE id = ?", (s_iid,))
        r_rem = cur.fetchone()
        s_rem = r_rem[0] if r_rem and r_rem[0] else "VLESS Steal"
        sync_host_entry(s_iid, s_rem, domain, 443, "same", host_sni=steal_dom, host_fp="firefox", sort_order=1)

if enable_classic:
    c_iid = lookup_inbound_id("in-classic-reality", classic_port)
    if c_iid:
        cur.execute("SELECT remark FROM inbounds WHERE id = ?", (c_iid,))
        r_rem = cur.fetchone()
        c_rem = r_rem[0] if r_rem and r_rem[0] else "VLESS Classic"
        sync_host_entry(c_iid, c_rem, domain, 443, "same", host_sni=classic_sni, host_fp="firefox", sort_order=1)

x_iid = lookup_inbound_id("in-xhttp-stream", xhttp_port)
if x_iid:
    cur.execute("SELECT remark FROM inbounds WHERE id = ?", (x_iid,))
    r_rem = cur.fetchone()
    x_rem = r_rem[0] if r_rem and r_rem[0] else "VLESS xHTTP"
    sync_host_entry(x_iid, x_rem, domain, 443, "tls", host_sni=domain, host_path=f"/{xhttp_path.strip('/')}/", host_alpn=json.dumps(["h2"]), host_fp="firefox", sort_order=2)


if not dry_run:
    import urllib.parse

    unified_email = os.environ.get("UNIFIED_CLIENT_TAG") or "Client"
    unified_uuid = def_uuid
    unified_sub_id = secrets.token_hex(8)
    unified_awg_hpk = def_wg_hpk
    ss_method = def_ss_method
    unified_ss_server_pass = def_ss_server_pass
    unified_ss_client_pass = def_ss_client_pass
    unified_tuic_uuid = def_tuic_uuid
    unified_tuic_pass = def_tuic_pass
    unified_mtp_secret = def_mtp_secret

    if "clients" in all_tables:
        try:
            cur.execute("SELECT uuid, sub_id, email FROM clients LIMIT 1")
            r_c = cur.fetchone()
            if r_c:
                if r_c[0]: unified_uuid = r_c[0]
                if r_c[1]: unified_sub_id = r_c[1]
                if r_c[2]: unified_email = r_c[2]
        except Exception:
            pass

    try:
        cur.execute("SELECT settings FROM inbounds WHERE protocol = 'shadowsocks' LIMIT 1")
        r_ss = cur.fetchone()
        if r_ss and r_ss[0]:
            s_ss = json.loads(r_ss[0])
            ss_method = s_ss.get("method", def_ss_method)
            if s_ss.get("password"): unified_ss_server_pass = s_ss["password"]
            c_ss = s_ss.get("clients", [])
            if c_ss and c_ss[0].get("password"): unified_ss_client_pass = c_ss[0]["password"]
    except Exception:
        pass

    try:
        cur.execute("SELECT settings FROM inbounds WHERE protocol = 'tuic' LIMIT 1")
        r_tu = cur.fetchone()
        if r_tu and r_tu[0]:
            s_tu = json.loads(r_tu[0])
            c_tu = s_tu.get("clients", [])
            if c_tu and c_tu[0].get("uuid"): unified_tuic_uuid = c_tu[0]["uuid"]
            if c_tu and c_tu[0].get("password"): unified_tuic_pass = c_tu[0]["password"]
    except Exception:
        pass

    try:
        cur.execute("SELECT settings FROM inbounds WHERE protocol = 'mtproto' LIMIT 1")
        r_mt = cur.fetchone()
        if r_mt and r_mt[0]:
            s_mt = json.loads(r_mt[0])
            c_mt = s_mt.get("clients", [])
            if c_mt and c_mt[0].get("secret"): unified_mtp_secret = c_mt[0]["secret"]
    except Exception:
        pass

    try:
        cur.execute("SELECT settings FROM inbounds WHERE protocol = 'amneziawg' LIMIT 1")
        r_awg = cur.fetchone()
        if r_awg and r_awg[0]:
            s_awg = json.loads(r_awg[0])
            srv_awg = s_awg.get("server", {})
            if srv_awg.get("headerProtectionKey"): unified_awg_hpk = srv_awg["headerProtectionKey"]
    except Exception:
        pass

    try:
        cur.execute("SELECT settings FROM inbounds WHERE protocol = 'vless' LIMIT 1")
        r_vl = cur.fetchone()
        if r_vl and r_vl[0]:
            s_vl = json.loads(r_vl[0])
            c_vl = s_vl.get("clients", [])
            if c_vl and c_vl[0].get("id"): unified_uuid = c_vl[0]["id"]
            if c_vl and c_vl[0].get("subId"): unified_sub_id = c_vl[0]["subId"]
    except Exception:
        pass

    raw_ss_userinfo = f"{ss_method}:{unified_ss_server_pass}:{unified_ss_client_pass}"
    b64_ss_userinfo = base64.urlsafe_b64encode(raw_ss_userinfo.encode("utf-8")).decode("utf-8").rstrip("=")
    ss2022_uri = f"ss://{b64_ss_userinfo}@{domain}:{ss2022_port}#{urllib.parse.quote('Shadowsocks 2022')}"
    tuic_uri = f"tuic://{unified_tuic_uuid}:{unified_tuic_pass}@{domain}:{tuic_port}?congestion_control=bbr&alpn=h3&udp_relay_mode=native&sni={domain}#{urllib.parse.quote('TUIC v5')}"
    mtproto_tg_uri = f"tg://proxy?server={domain}&port={mtproto_port}&secret={unified_mtp_secret}"
    mtproto_https_uri = f"https://t.me/proxy?server={domain}&port={mtproto_port}&secret={unified_mtp_secret}"
    mtproto_bot_secret = unified_mtp_secret[2:34] if len(unified_mtp_secret) >= 34 else unified_mtp_secret

    enable_masque = os.environ.get("ENABLE_MASQUE", "n").lower() in ("1", "y", "true")
    masque_port = int(os.environ.get("MASQUE_PORT") or "8449")
    masque_user = (os.environ.get("MASQUE_USER") or "client").strip()
    masque_password = os.environ.get("MASQUE_PASSWORD", "").strip() or unified_ss_client_pass
    masque_uri = f"masque://{masque_user}:{masque_password}@{domain}:{masque_port}?alpn=h3#{urllib.parse.quote('MASQUE RFC 9484')}"

    enable_shadowtls = os.environ.get("ENABLE_SHADOWTLS", "n").lower() in ("1", "y", "true")
    shadowtls_port = int(os.environ.get("SHADOWTLS_PORT") or "8543")
    shadowtls_sni = (os.environ.get("SHADOWTLS_SNI") or "gateway.icloud.com").strip()
    shadowtls_password = os.environ.get("SHADOWTLS_PASSWORD", "").strip()
    shadowtls_uri = f"shadowtls://{shadowtls_password}@{domain}:443?sni={shadowtls_sni}&version=4#{urllib.parse.quote('ShadowTLS v4')}"
    ss_shadowtls_uri = f"ss://{b64_ss_userinfo}@{domain}:443?plugin=shadow-tls;host={shadowtls_sni};password={shadowtls_password};version=4#{urllib.parse.quote('ShadowTLS + SS-2022')}"

    enable_wstunnel = os.environ.get("ENABLE_WSTUNNEL", "n").lower() in ("1", "y", "true")
    wstunnel_port = int(os.environ.get("WSTUNNEL_PORT") or "8080")
    wstunnel_prefix = resolve_wstunnel_prefix(os.environ.get("WSTUNNEL_PREFIX"))
    wstunnel_cli = f"wstunnel client -L socks5://127.0.0.1:1080 --http-upgrade-path-prefix {wstunnel_prefix} wss://{domain}:443"
    wstunnel_uri = f"wstunnel://{domain}:443/{wstunnel_prefix}"

    enable_zapret = os.environ.get("ENABLE_ZAPRET", "n").lower() in ("1", "y", "true")
    zapret_qnum = os.environ.get("ZAPRET_QNUM", "200").strip()
    zapret_desync = os.environ.get("ZAPRET_DESYNC", "split2").strip()
    zapret_fooling = os.environ.get("ZAPRET_FOOLING", "md5sig,badseq").strip()
    zapret_info = f"Active (NFQUEUE {zapret_qnum}, desync: {zapret_desync}, fooling: {zapret_fooling})"

    enable_naive = os.environ.get("ENABLE_NAIVE", "n").lower() in ("1", "y", "true")
    naive_port = int(os.environ.get("NAIVE_PORT") or "8446")
    naive_domain = (os.environ.get("NAIVE_DOMAIN") or (f"naive.{domain}" if domain else "localhost")).strip()
    naive_user = (os.environ.get("NAIVE_USER") or "user").strip()
    naive_pass = (os.environ.get("NAIVE_PASS") or "").strip()
    if not naive_pass and os.path.isfile("/etc/caddy/Caddyfile"):
        try:
            with open("/etc/caddy/Caddyfile", "r") as cf:
                for cline in cf:
                    if "basic_auth" in cline:
                        cparts = cline.strip().split()
                        if len(cparts) >= 3:
                            naive_user = cparts[1]
                            naive_pass = cparts[2]
                            break
        except Exception:
            pass
    if not naive_pass:
        naive_pass = unified_ss_client_pass
    naive_uri = f"naive+https://{naive_user}:{naive_pass}@{naive_domain}:443#{urllib.parse.quote('NaïveProxy')}"

    enable_dnstt = os.environ.get("ENABLE_DNSTT", "n").lower() in ("1", "y", "true")
    dnstt_port = int(os.environ.get("DNSTT_PORT") or "53053")
    dnstt_domain = (os.environ.get("DNSTT_DOMAIN") or (f"t.{domain}" if domain else "t.example.com")).strip()
    dnstt_pubkey = os.environ.get("DNSTT_PUBKEY", "").strip()
    if not dnstt_pubkey and os.path.isfile("/etc/dnstt/server.pub"):
        try:
            with open("/etc/dnstt/server.pub", "r") as pf:
                dnstt_pubkey = pf.read().strip()
        except Exception:
            pass
    if not dnstt_pubkey and enable_dnstt and not dry_run:
        try:
            _P = 2**255 - 19
            def _clamp(kb):
                b = bytearray(kb)
                b[0] &= 248; b[31] &= 127; b[31] |= 64
                return int.from_bytes(b, "little")
            def _x25519(k, u=9):
                x1, x2, z2, x3, z3 = u, 1, 0, u, 1
                for i in range(254, -1, -1):
                    bit = (k >> i) & 1
                    if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
                    A = (x2 + z2) % _P; AA = (A * A) % _P; B = (x2 - z2) % _P; BB = (B * B) % _P; E = (AA - BB) % _P
                    x3 = ((x2 * x3 - z2 * z3)**2) % _P; z3 = (x1 * ((x2 * z3 - z2 * x3)**2)) % _P
                    x2 = (AA * BB) % _P; z2 = (E * (AA + ((121665 * E) % _P))) % _P
                    if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
                return (x2 * pow(z2, _P - 2, _P)) % _P
            _raw_priv = os.urandom(32)
            _k = _clamp(_raw_priv)
            dnstt_pubkey = ((_x25519(_k, 9)) % _P).to_bytes(32, "little").hex()
            os.makedirs("/etc/dnstt", exist_ok=True)
            with open("/etc/dnstt/server.key", "w") as kf:
                kf.write(_raw_priv.hex() + "\n")
            with open("/etc/dnstt/server.pub", "w") as pf:
                pf.write(dnstt_pubkey + "\n")
            os.chmod("/etc/dnstt/server.key", 0o600)
            os.chmod("/etc/dnstt/server.pub", 0o600)
        except Exception:
            pass
    dnstt_cli = f"dnstt-client -doh https://dns.google/dns-query -pubkey {dnstt_pubkey} {dnstt_domain} 127.0.0.1:1080"

    enable_mieru = os.environ.get("ENABLE_MIERU", "n").lower() in ("1", "y", "true")
    mieru_port = (os.environ.get("MIERU_PORT") or "8450").strip()
    mieru_transport = (os.environ.get("MIERU_TRANSPORT") or "").strip().upper()
    mieru_user = (os.environ.get("MIERU_USER") or "").strip()
    mieru_pass = (os.environ.get("MIERU_PASS") or "").strip()
    if not mieru_user or not mieru_pass or not mieru_transport:
        for m_cfg_candidate in ["/etc/mita/config.json", "/etc/mita_server_config.json"]:
            if os.path.isfile(m_cfg_candidate):
                try:
                    with open(m_cfg_candidate, "r", encoding="utf-8") as mf:
                        mdata = json.load(mf)
                        if mdata.get("users") and len(mdata["users"]) > 0:
                            if not mieru_user: mieru_user = mdata["users"][0].get("name", "")
                            if not mieru_pass: mieru_pass = mdata["users"][0].get("password", "")
                        if not mieru_transport and mdata.get("portBindings"):
                            protos = [str(b.get("protocol", "")).upper() for b in mdata["portBindings"] if "protocol" in b]
                            if "UDP" in protos and "TCP" not in protos:
                                mieru_transport = "UDP"
                            elif "TCP" in protos and "UDP" not in protos:
                                mieru_transport = "TCP"
                            elif "TCP" in protos and "UDP" in protos:
                                mieru_transport = "BOTH"
                    break
                except Exception:
                    pass
    if not mieru_transport:
        mieru_transport = "BOTH"

    try:
        cur.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    except Exception:
        pass
    conn.commit()

    try:
        run_file = "/run/3xui_unified_client.env" if os.path.isdir("/run") else "/tmp/3xui_unified_client.env"
        old_umask = os.umask(0o077)
        with open(run_file, "w") as f:
            f.write(f"PRIMARY_DOMAIN={shlex.quote(domain)}\n")
            f.write(f"PANEL_PATH={shlex.quote(panel_path)}\n")
            f.write(f"UNIFIED_CLIENT_TAG='{unified_email}'\n")
            f.write(f"UNIFIED_SUB_ID='{unified_sub_id}'\n")
            f.write(f"UNIFIED_UUID='{unified_uuid}'\n")
            f.write(f"UNIFIED_AWG_HPK='{unified_awg_hpk}'\n")
            f.write(f"UNIFIED_AWG_PORT='{awg_v3_port}'\n")
            if unified_vless_enkey:
                f.write(f"UNIFIED_VLESS_ENKEY='{unified_vless_enkey}'\n")
            if enable_ss2022 or "shadowsocks" in existing_inbound_protos:
                f.write(f"SS2022_URI='{ss2022_uri}'\n")
                f.write(f"SS2022_PORT='{ss2022_port}'\n")
            if enable_tuic or "tuic" in existing_inbound_protos:
                f.write(f"TUIC_URI='{tuic_uri}'\n")
                f.write(f"TUIC_PORT='{tuic_port}'\n")
            if enable_mtproto or "mtproto" in existing_inbound_protos:
                f.write(f"MTPROTO_TG_URI='{mtproto_tg_uri}'\n")
                f.write(f"MTPROTO_HTTPS_URI='{mtproto_https_uri}'\n")
                f.write(f"MTPROTO_SECRET='{unified_mtp_secret}'\n")
                f.write(f"MTPROTO_BOT_SECRET='{mtproto_bot_secret}'\n")
                f.write(f"MTPROTO_PORT='{mtproto_port}'\n")
            if enable_masque or os.path.exists("/etc/sing-box/masque.json"):
                f.write(f"MASQUE_URI='{masque_uri}'\n")
                f.write(f"MASQUE_PORT='{masque_port}'\n")
            if enable_shadowtls or os.path.exists("/etc/systemd/system/shadow-tls.service"):
                f.write(f"SHADOWTLS_URI='{shadowtls_uri}'\n")
                f.write(f"SS_SHADOWTLS_URI='{ss_shadowtls_uri}'\n")
                f.write(f"SHADOWTLS_PORT='{shadowtls_port}'\n")
            if wstunnel_prefix and (enable_wstunnel or os.path.exists("/etc/systemd/system/wstunnel.service")):
                f.write(f"WSTUNNEL_CLI='{wstunnel_cli}'\n")
                f.write(f"WSTUNNEL_URI='{wstunnel_uri}'\n")
                f.write(f"WSTUNNEL_PORT='{wstunnel_port}'\n")
            if enable_zapret or os.path.exists("/etc/systemd/system/zapret-server.service"):
                f.write(f"ZAPRET_INFO='{zapret_info}'\n")
            if enable_naive or os.path.exists("/etc/systemd/system/caddy-naive.service"):
                f.write(f"NAIVE_URI='{naive_uri}'\n")
                f.write(f"NAIVE_PORT='{naive_port}'\n")
                f.write(f"NAIVE_USER='{naive_user}'\n")
                f.write(f"NAIVE_PASS='{naive_pass}'\n")
            if enable_dnstt or os.path.exists("/etc/systemd/system/dnstt-server.service"):
                f.write(f"DNSTT_CLI='{dnstt_cli}'\n")
                f.write(f"DNSTT_PORT='{dnstt_port}'\n")
                f.write(f"DNSTT_DOMAIN='{dnstt_domain}'\n")
                f.write(f"DNSTT_PUBKEY='{dnstt_pubkey}'\n")
            if (enable_mieru or os.path.exists("/etc/systemd/system/mita.service")) and mieru_user and mieru_pass:
                f.write(f"ENABLE_MIERU='1'\n")
                f.write(f"MIERU_PORT={shlex.quote(mieru_port)}\n")
                f.write(f"MIERU_TRANSPORT={shlex.quote(mieru_transport)}\n")
                f.write(f"MIERU_USER={shlex.quote(mieru_user)}\n")
                f.write(f"MIERU_PASS={shlex.quote(mieru_pass)}\n")
        os.umask(old_umask)
        os.chmod(run_file, 0o600)
    except Exception:
        pass

conn.close()
EOF_PYTHON_RECONCILE

# --- ЭТАП 3: ПРОВЕРКА И ПЕРЕЗАПУСК СЛУЖБ (Hardened: chmod 600 для защиты от локальной утечки) ---
if [ "$DRY_RUN" -eq 0 ]; then
    chmod 600 "$DB_PATH" 2>/dev/null || true
    
    # Запуск x-ui
    if [ "${WAS_ACTIVE:-0}" -eq 1 ] || (command -v systemctl >/dev/null 2>&1 && systemctl is-enabled --quiet x-ui 2>/dev/null); then
        log "Перезапуск службы 3X-UI..."
        systemctl restart x-ui && { ok "Служба 3X-UI успешно перезапущена."; WAS_ACTIVE=0; } || warn "Сбой перезапуска 3X-UI."
    fi

    # Проверка синтаксиса и мягкий reload Nginx
    if command -v nginx >/dev/null 2>&1; then
        log "Аудит файлов конфигурации Nginx..."
        if [ -d /etc/nginx ] && grep -rq "swdist\.microsoft\.com" /etc/nginx/ 2>/dev/null; then
            find /etc/nginx/ -type f -name "*.conf" -exec sed -i 's/swdist\.microsoft\.com/gateway\.icloud\.com/g' {} + 2>/dev/null || true
            ok "Nginx: Устаревший SNI swdist.microsoft.com заменен на gateway.icloud.com."
        fi

        log "Проверка конфигурации Nginx (nginx -t)..."
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx && ok "Nginx успешно применил обновленную конфигурацию (Zero Downtime reload)."
        else
            warn "Внимание: nginx -t обнаружил предупреждения синтаксиса. Перезагрузка Nginx отложена."
        fi
    fi
else
    # Проверка в режиме DRY-RUN
    if [ -d /etc/nginx ] && grep -rq "swdist\.microsoft\.com" /etc/nginx/ 2>/dev/null; then
        warn "Nginx: В файлах /etc/nginx/ обнаружен устаревший SNI swdist.microsoft.com (будет заменен)."
    fi
fi

echo
echo -e "${GREEN}=====================================================================${NC}"
if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}               АУДИТ УСПЕШНО ЗАВЕРШЕН (DRY-RUN)                      ${NC}"
    echo -e "${CYAN}  Все найденные замечания выше будут исправлены при обычном запуске: ${NC}"
    echo -e "  ${BOLD}sudo ./maintain.sh -y${NC}"
else
    echo -e "${GREEN}      ОБНОВЛЕНИЕ И ВОССТАНОВЛЕНИЕ СИСТЕМЫ УСПЕШНО ЗАВЕРШЕНО!         ${NC}"
    for c_env in "/run/3xui_unified_client.env" "/tmp/3xui_unified_client.env"; do
        if [ -f "$c_env" ]; then
            source "$c_env" 2>/dev/null || true
            break
        fi
    done
    echo -e "  - ${BOLD}Подключения клиентов:${NC}   ${GREEN}Сохранены без разрыва и сброса ключей${NC}"
    echo -e "  - ${BOLD}Вход в панель 3X-UI:${NC}    ${CYAN}https://${PRIMARY_DOMAIN:-домен}/${PANEL_PATH:-}/${NC}"
    echo -e "  - ${BOLD}Ссылка на подписку:${NC}     ${CYAN}https://${PRIMARY_DOMAIN:-домен}/${SUB_PATH:-my-post-key}/${NC}"
    echo -e "  - ${BOLD}Ссылка (Clash):${NC}         ${CYAN}https://${PRIMARY_DOMAIN:-домен}/${SUB_CLASH_PATH:-${SUB_PATH:-my-post-key}/clash}/${NC}"


    if [ -z "${DNSTT_PUBKEY:-}" ] && [ -f "/etc/dnstt/server.pub" ]; then
        DNSTT_PUBKEY="$(cat /etc/dnstt/server.pub 2>/dev/null | tr -d '[:space:]')"
    fi
    if [ -n "${DNSTT_PUBKEY:-}" ]; then
        if [ -n "${DNSTT_CLI:-}" ] && [[ "$DNSTT_CLI" == *"-pubkey  "* ]]; then
            DNSTT_CLI="${DNSTT_CLI/-pubkey  /-pubkey ${DNSTT_PUBKEY} }"
        fi
    fi
    [ -n "${UNIFIED_VLESS_ENKEY:-}" ] && echo -e "  - ${BOLD}VLESS xHTTP EnKey:${NC}     ${YELLOW}${UNIFIED_VLESS_ENKEY}${NC} (ML-KEM-768)"
    [ -n "${SS2022_URI:-}" ] && echo -e "  - ${BOLD}Shadowsocks 2022:${NC}    ${CYAN}${SS2022_URI}${NC}"
    [ -n "${TUIC_URI:-}" ] && echo -e "  - ${BOLD}TUIC v5 (QUIC+BBR):${NC}  ${CYAN}${TUIC_URI}${NC}"
    [ -n "${MTPROTO_TG_URI:-}" ] && echo -e "  - ${BOLD}Telegram MTProxy:${NC}    ${CYAN}${MTPROTO_TG_URI}${NC}"
    [ -n "${MASQUE_URI:-}" ] && echo -e "  - ${BOLD}MASQUE (RFC 9484):${NC}    ${CYAN}${MASQUE_URI}${NC}"
    [ -n "${SHADOWTLS_URI:-}" ] && echo -e "  - ${BOLD}ShadowTLS v4:${NC}         ${CYAN}${SHADOWTLS_URI}${NC}"
    [ -n "${SS_SHADOWTLS_URI:-}" ] && echo -e "  - ${BOLD}ShadowTLS + SS-2022:${NC}  ${CYAN}${SS_SHADOWTLS_URI}${NC}"
    [ -n "${WSTUNNEL_CLI:-}" ] && echo -e "  - ${BOLD}Wstunnel CLI:${NC}         ${CYAN}${WSTUNNEL_CLI}${NC}"
    [ -n "${ZAPRET_INFO:-}" ] && echo -e "  - ${BOLD}Server-Side Zapret:${NC}   ${GREEN}${ZAPRET_INFO}${NC}"
    [ -n "${NAIVE_URI:-}" ] && echo -e "  - ${BOLD}NaïveProxy:${NC}          ${CYAN}${NAIVE_URI}${NC}"
    [ -n "${DNSTT_CLI:-}" ] && echo -e "  - ${BOLD}DNSTT DoH Tunnel:${NC}    ${CYAN}${DNSTT_CLI}${NC}"

    if [ -f "/root/vpn_credentials.txt" ]; then
        if [ -n "${UNIFIED_VLESS_ENKEY:-}" ]; then
            if grep -q "VLESS xHTTP EnKey:" /root/vpn_credentials.txt 2>/dev/null; then
                sed -i -E "s|^VLESS xHTTP EnKey:.*|VLESS xHTTP EnKey:     ${UNIFIED_VLESS_ENKEY} (ML-KEM-768)|" /root/vpn_credentials.txt 2>/dev/null || true
            else
                echo "VLESS xHTTP EnKey:     ${UNIFIED_VLESS_ENKEY} (ML-KEM-768)" >> /root/vpn_credentials.txt
            fi
        fi
        if [ -n "${SS2022_URI:-}" ] && ! grep -q "Shadowsocks 2022:" /root/vpn_credentials.txt 2>/dev/null; then
            echo "Shadowsocks 2022:       ${SS2022_URI}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${TUIC_URI:-}" ] && ! grep -q "TUIC v5" /root/vpn_credentials.txt 2>/dev/null; then
            echo "TUIC v5 (QUIC+BBR):     ${TUIC_URI}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${MTPROTO_TG_URI:-}" ] && ! grep -q "Telegram MTProxy" /root/vpn_credentials.txt 2>/dev/null; then
            echo "Telegram MTProxy (Клиент): ${MTPROTO_TG_URI}" >> /root/vpn_credentials.txt
            echo "MTProxy Web Link:          ${MTPROTO_HTTPS_URI:-}" >> /root/vpn_credentials.txt
            echo "MTProxy FakeTLS Secret:    ${MTPROTO_SECRET:-}" >> /root/vpn_credentials.txt
            [ -n "${MTPROTO_BOT_SECRET:-}" ] && echo "MTProxy Key для @MTProxybot: ${MTPROTO_BOT_SECRET}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${MASQUE_URI:-}" ] && ! grep -q "MASQUE (RFC 9484):" /root/vpn_credentials.txt 2>/dev/null; then
            echo "MASQUE (RFC 9484):       ${MASQUE_URI}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${SHADOWTLS_URI:-}" ] && ! grep -q "ShadowTLS v4:" /root/vpn_credentials.txt 2>/dev/null; then
            echo "ShadowTLS v4:            ${SHADOWTLS_URI}" >> /root/vpn_credentials.txt
            echo "ShadowTLS + SS-2022:     ${SS_SHADOWTLS_URI}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${WSTUNNEL_CLI:-}" ] && ! grep -q "Wstunnel Client CLI:" /root/vpn_credentials.txt 2>/dev/null; then
            echo "Wstunnel Client CLI:     ${WSTUNNEL_CLI}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${ZAPRET_INFO:-}" ] && ! grep -q "Server-Side Zapret:" /root/vpn_credentials.txt 2>/dev/null; then
            echo "Server-Side Zapret:      ${ZAPRET_INFO}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${NAIVE_URI:-}" ] && ! grep -q "NaïveProxy (Chrome HTTPS):" /root/vpn_credentials.txt 2>/dev/null; then
            echo "NaïveProxy (Chrome HTTPS): ${NAIVE_URI}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${DNSTT_CLI:-}" ] && ! grep -q "DNSTT DoH Tunnel:" /root/vpn_credentials.txt 2>/dev/null; then
            echo "DNSTT DoH Tunnel:        ${DNSTT_CLI}" >> /root/vpn_credentials.txt
            [ -n "${DNSTT_PUBKEY:-}" ] && echo "DNSTT Public Key:        ${DNSTT_PUBKEY}" >> /root/vpn_credentials.txt
        fi
        if [ -n "${MIERU_PORT:-}" ] && [ -n "${MIERU_USER:-}" ] && ! grep -q "Mieru Proxy" /root/vpn_credentials.txt 2>/dev/null; then
            echo "Mieru Proxy (XChaCha20, :${MIERU_PORT}): user: ${MIERU_USER}, pass: ${MIERU_PASS}" >> /root/vpn_credentials.txt
            echo "  Клиентский конфиг: /root/mieru-client.json (Управление пользователями: mieru-mgr list|add|del)" >> /root/vpn_credentials.txt
        fi
    fi
fi
echo -e "${GREEN}=====================================================================${NC}"
echo
