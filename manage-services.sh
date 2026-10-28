#!/usr/bin/env bash
# ==============================================================================
# manage-services.sh - Next-Gen Inbounds & Protocols Manager for Dokploy
# ==============================================================================
# Управление протоколами нового поколения (MASQUE, ShadowTLS, NaiveProxy, Zapret, Wstunnel)
# и оркестрация интеграции со стеком Dokploy (Traefik).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
COMPOSE_DIR="${SCRIPT_DIR}/compose"
ENV_FILE="${COMPOSE_DIR}/.env"
ENV_EXAMPLE="${COMPOSE_DIR}/.env.example"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()   { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
die()   { echo -e "${RED}[x] ОШИБКА:${NC} $*" >&2; exit 1; }

get_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        die "Docker Compose не найден. Установите Docker и Docker Compose."
    fi
}

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
        candidate="$directory/server-setup.env"
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
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

            # Security check: forbid overwriting critical system environment variables
            local upper_key="${key^^}"
            case "$upper_key" in
                PATH|LD_PRELOAD|LD_LIBRARY_PATH|LD_AUDIT|IFS|SHELL|EUID|UID|PPID|BASH_ENV|ENV|CDPATH|PYTHONPATH|PYTHONHOME|PROMPT_COMMAND|BASH_OPTS|SHELLOPTS|GLOBIGNORE|BASH_XTRACEFD)
                    echo "[ERROR] Security violation in $env_file line $line_no: overwriting critical system variable '$key' is forbidden!" >&2
                    return 1
                    ;;
            esac

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

detect_server_location_prefix() {
    local cache_file="/run/setup_mask_server_prefix"
    if [ ! -d /run ] || ! touch /run/.test_w 2>/dev/null; then
        cache_file="/tmp/setup_mask_server_prefix"
    else
        rm -f /run/.test_w 2>/dev/null || true
    fi

    if [ -f "$cache_file" ]; then
        local cached
        cached="$(cat "$cache_file" 2>/dev/null | tr -d '\r\n')"
        if [ -n "$cached" ]; then
            printf '%s\n' "$cached"
            return 0
        fi
    fi

    local py_cmd="${PYTHON_CMD:-python3}"
    command -v "$py_cmd" >/dev/null 2>&1 || py_cmd="python"

    local detected=""
    if command -v "$py_cmd" >/dev/null 2>&1; then
        detected=$("$py_cmd" - << 'EOF_GEO_PY' 2>/dev/null || true
import json, re, sys, urllib.request

def country_to_flag(code):
    if not code or len(code) != 2:
        return ''
    return ''.join(chr(127397 + ord(c.upper())) for c in code if 'A' <= c.upper() <= 'Z')

loc = ''
colo = ''

# 1. Cloudflare trace (native Anycast, directly returns loc=ISO and colo=IATA)
try:
    req = urllib.request.Request('https://1.1.1.1/cdn-cgi/trace', headers={'User-Agent': 'curl/7.68.0'})
    with urllib.request.urlopen(req, timeout=2) as resp:
        text = resp.read().decode('utf-8', errors='ignore')
        m_loc = re.search(r'^loc=([A-Za-z]{2})$', text, re.MULTILINE)
        m_colo = re.search(r'^colo=([A-Za-z]{3})$', text, re.MULTILINE)
        if m_loc:
            loc = m_loc.group(1).upper()
        if m_colo:
            colo = m_colo.group(1).upper()
except Exception:
    pass

# 2. Fallback to ipinfo.io if Cloudflare trace is unreachable
if not loc:
    try:
        req = urllib.request.Request('https://ipinfo.io/json', headers={'User-Agent': 'curl/7.68.0'})
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read().decode('utf-8', errors='ignore'))
            loc = data.get('country', '').strip().upper()
            city = data.get('city', '').strip()
            clean_city = re.sub(r'[^a-zA-Z]', '', city)
            if len(clean_city) >= 3 and not colo:
                colo = clean_city[:3].upper()
    except Exception:
        pass

flag = country_to_flag(loc)
if loc and colo:
    out = f"{flag} {loc}-{colo}".strip()
elif loc:
    out = f"{flag} {loc}".strip()
else:
    out = ""

if out:
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except Exception:
        pass
    print(out)
EOF_GEO_PY
)
    fi

    # Secondary fallback to curl + Cloudflare trace if python is unavailable
    if [ -z "$detected" ] && command -v curl >/dev/null 2>&1; then
        local trace_out
        trace_out=$(curl -s4 --connect-timeout 2 --max-time 3 https://1.1.1.1/cdn-cgi/trace 2>/dev/null || true)
        local loc_c colo_c
        loc_c=$(printf '%s\n' "$trace_out" | awk -F= '$1=="loc"{print $2; exit}' | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
        colo_c=$(printf '%s\n' "$trace_out" | awk -F= '$1=="colo"{print $2; exit}' | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
        if [[ "$loc_c" =~ ^[A-Z]{2}$ ]]; then
            if [ -n "$colo_c" ] && [[ "$colo_c" =~ ^[A-Z]{3}$ ]]; then
                detected="$loc_c-$colo_c"
            else
                detected="$loc_c"
            fi
        fi
    fi

    if [ -n "$detected" ]; then
        printf '%s\n' "$detected" > "$cache_file" 2>/dev/null || true
        printf '%s\n' "$detected"
        return 0
    fi
    return 1
}

generate_secret_token() {
    # 16 bytes = 128 bits. Never replace a failed entropy read with $RANDOM.
    local token
    token=$(od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]') || return 1
    [[ "$token" =~ ^[0-9a-f]{32}$ ]] || { warn "Не удалось получить 128 бит случайности."; return 1; }
    printf '%s' "$token"
}

generate_urlsafe_token() {
    local nbytes="${1:-16}"
    local token=""
    if command -v python3 >/dev/null 2>&1; then
        token="$(python3 -c "import secrets, sys; print(secrets.token_urlsafe(int(sys.argv[1])))" "$nbytes" 2>/dev/null || true)"
    fi
    if [ -z "$token" ] && command -v openssl >/dev/null 2>&1; then
        token="$(openssl rand -base64 "$nbytes" 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$(( nbytes * 4 / 3 ))" || true)"
    fi
    if [ -z "$token" ] && [ -r /dev/urandom ]; then
        token="$(tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c "$nbytes" || true)"
    fi
    if [ -z "$token" ]; then
        token="$(generate_secret_token 2>/dev/null | head -c "$nbytes")"
    fi
    printf '%s' "$token"
}

generate_base64_token() {
    local nbytes="${1:-32}"
    local token=""
    if command -v openssl >/dev/null 2>&1; then
        token="$(openssl rand -base64 "$nbytes" 2>/dev/null || true)"
    fi
    if [ -z "$token" ] && command -v python3 >/dev/null 2>&1; then
        token="$(python3 -c "import secrets, base64, sys; print(base64.b64encode(secrets.token_bytes(int(sys.argv[1]))).decode())" "$nbytes" 2>/dev/null || true)"
    fi
    if [ -z "$token" ] && [ -r /dev/urandom ]; then
        token="$(head -c "$nbytes" /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -d '\n' || true)"
    fi
    printf '%s' "$token"
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

ensure_env() {
    if [ ! -f "$ENV_FILE" ]; then
        if [ -f "$ENV_EXAMPLE" ]; then
            log "Создание конфигурации ${ENV_FILE} из шаблона..."
            cp "$ENV_EXAMPLE" "$ENV_FILE"
            # Генерация криптографических паролей
            local rand_masque rand_stls rand_naive rand_ws
            rand_masque="$(generate_urlsafe_token 16)"
            rand_stls="$(generate_urlsafe_token 16)"
            rand_naive="$(generate_urlsafe_token 16)"
            rand_ws="$(generate_urlsafe_token 16)"

            sed -i "s/ChangeMeSecretMasquePass2026!/${rand_masque}/" "$ENV_FILE" 2>/dev/null || true
            sed -i "s/ChangeMeShadowTlsPassword2026!/${rand_stls}/" "$ENV_FILE" 2>/dev/null || true
            sed -i "s/ChangeMeNaivePassword2026!/${rand_naive}/" "$ENV_FILE" 2>/dev/null || true
            sed -i "s/ChangeMeWstunnelSecret2026!/${rand_ws}/" "$ENV_FILE" 2>/dev/null || true
            ok "Конфигурация инициализирована с новыми ключами безопасности."
        else
            die "Шаблон ${ENV_EXAMPLE} не найден."
        fi
    fi
}

ensure_configs() {
    ensure_env

    local masque_tpl="${COMPOSE_DIR}/sing-box-masque/config.json.template"
    local masque_cfg="${COMPOSE_DIR}/sing-box-masque/config.json"
    local naive_tpl="${COMPOSE_DIR}/naiveproxy/Caddyfile.template"
    local naive_cfg="${COMPOSE_DIR}/naiveproxy/Caddyfile"

    # Чтение переменных окружения
    load_config_data_safe "$ENV_FILE" || die "Ошибка загрузки конфигурации из $ENV_FILE"

    # 1. Генерация sing-box MASQUE config.json при отсутствии
    if [ ! -f "$masque_cfg" ] && [ -f "$masque_tpl" ]; then
        log "Генерация конфигурации Sing-box MASQUE (${masque_cfg})..."
        local m_port="${MASQUE_PORT:-8449}"
        local m_user="${MASQUE_USER:-client}"
        local m_pass="${MASQUE_PASS:-ChangeMeSecretMasquePass2026!}"
        local m_dom="${PRIMARY_DOMAIN:-yourdomain.online}"
        local m_cert="${MASQUE_CERT_PATH:-/etc/ssl/certs/fullchain.pem}"
        local m_key="${MASQUE_KEY_PATH:-/etc/ssl/certs/privkey.pem}"

        if command -v python3 >/dev/null 2>&1; then
            python3 -c "
import json
with open('$masque_tpl', 'r', encoding='utf-8') as f:
    data = json.load(f)
for ib in data.get('inbounds', []):
    if ib.get('type') == 'masque':
        ib['listen_port'] = int('$m_port')
        if 'users' in ib and ib['users']:
            ib['users'][0]['username'] = '$m_user'
            ib['users'][0]['password'] = '$m_pass'
        if 'tls' in ib:
            ib['tls']['server_name'] = '$m_dom'
            ib['tls']['certificate_path'] = '$m_cert'
            ib['tls']['key_path'] = '$m_key'
with open('$masque_cfg', 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || cp "$masque_tpl" "$masque_cfg"
        else
            sed -e "s|\"listen_port\": 8449|\"listen_port\": ${m_port}|g" \
                -e "s|\"username\": \"client\"|\"username\": \"${m_user}\"|g" \
                -e "s|\"password\": \"CHANGE_ME_PASSWORD\"|\"password\": \"${m_pass}\"|g" \
                -e "s|\"server_name\": \"yourdomain.online\"|\"server_name\": \"${m_dom}\"|g" \
                -e "s|/etc/ssl/certs/fullchain.pem|${m_cert}|g" \
                -e "s|/etc/ssl/certs/privkey.pem|${m_key}|g" \
                "$masque_tpl" > "$masque_cfg"
        fi
        ok "Конфигурация Sing-box MASQUE инициализирована."
    fi

    # 2. Инициализация NaïveProxy Caddyfile при отсутствии
    if [ ! -f "$naive_cfg" ] && [ -f "$naive_tpl" ]; then
        log "Создание конфигурации NaïveProxy Caddyfile (${naive_cfg})..."
        cp "$naive_tpl" "$naive_cfg"
        ok "Конфигурация NaïveProxy Caddyfile инициализирована."
    fi
}

get_compose_file() {
    local dokploy_net_exists=0
    if command -v docker >/dev/null 2>&1; then
        docker network inspect dokploy-network >/dev/null 2>&1 && dokploy_net_exists=1 || true
    fi

    if [ "$dokploy_net_exists" -eq 1 ]; then
        echo "${COMPOSE_DIR}/docker-compose.dokploy.yml"
    else
        echo "${COMPOSE_DIR}/docker-compose.nextgen.yml"
    fi
}

cmd_status() {
    ensure_configs
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    local compose_file
    compose_file=$(get_compose_file)

    echo ""
    echo -e "${BOLD}${CYAN}=== СТАТУС СЕРВИСОВ СЛЕДУЮЩЕГО ПОКОЛЕНИЯ & DOKPLOY ===${NC}"
    echo -e "Используемый стек: ${YELLOW}${compose_file}${NC}"
    echo ""

    if docker network inspect dokploy-network >/dev/null 2>&1; then
        ok "Сеть Dokploy (dokploy-network): ${GREEN}ОБНАРУЖЕНА (Режим интеграции с Traefik)${NC}"
    else
        log "Сеть Dokploy (dokploy-network): ${YELLOW}Не обнаружена (Автономный режим)${NC}"
    fi

    $compose_cmd --env-file "$ENV_FILE" -f "$compose_file" ps
    echo ""

    # Проверка прослушивания ключевых портов
    echo -e "${BOLD}Прослушивание портов на хосте:${NC}"
    for proto_port in "UDP:8449:MASQUE" "TCP:8543:ShadowTLS" "TCP:8446:NaïveProxy" "TCP:8080:Wstunnel-Direct"; do
        IFS=":" read -r proto port name <<< "$proto_port"
        local flag="-t"
        [ "$proto" = "UDP" ] && flag="-u"
        if ss -l -n "$flag" 2>/dev/null | grep -q ":${port}\b"; then
            echo -e "  [+] ${GREEN}${name}${NC} (${proto} ${port}): ${GREEN}АКТИВЕН${NC}"
        else
            echo -e "  [-] ${YELLOW}${name}${NC} (${proto} ${port}): ${YELLOW}НЕ СЛУШАЕТ${NC}"
        fi
    done

    # Проверка правила iptables Zapret
    echo -e "${BOLD}Статус Server-Side Zapret (connbytes 1:6 NFQUEUE):${NC}"
    if iptables -t mangle -C POSTROUTING -p tcp -m connbytes --connbytes 1:6 --connbytes-mode packets --connbytes-dir original -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num 200 --queue-bypass 2>/dev/null; then
        echo -e "  [+] ${GREEN}iptables mangle правило NFQUEUE connbytes 1:6 активно${NC}"
    else
        echo -e "  [-] ${YELLOW}iptables mangle правило NFQUEUE не активно${NC}"
    fi
}

cmd_up() {
    ensure_configs
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    local compose_file
    compose_file=$(get_compose_file)
    local svc="${1:-}"

    log "Запуск сервисов из ${compose_file}..."
    if [ -n "$svc" ]; then
        $compose_cmd --env-file "$ENV_FILE" -f "$compose_file" up -d "$svc"
    else
        $compose_cmd --env-file "$ENV_FILE" -f "$compose_file" up -d
    fi
    ok "Сервисы успешно запущены."
}

cmd_down() {
    ensure_configs
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    local compose_file
    compose_file=$(get_compose_file)
    local svc="${1:-}"

    log "Остановка сервисов из ${compose_file}..."
    if [ -n "$svc" ]; then
        $compose_cmd --env-file "$ENV_FILE" -f "$compose_file" stop "$svc"
    else
        $compose_cmd --env-file "$ENV_FILE" -f "$compose_file" down
    fi
    ok "Сервисы остановлены."
}

cmd_restart() {
    ensure_configs
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    local compose_file
    compose_file=$(get_compose_file)
    local svc="${1:-}"

    log "Перезапуск сервисов..."
    if [ -n "$svc" ]; then
        $compose_cmd --env-file "$ENV_FILE" -f "$compose_file" restart "$svc"
    else
        $compose_cmd --env-file "$ENV_FILE" -f "$compose_file" restart
    fi
    ok "Перезапуск завершен."
}

cmd_logs() {
    ensure_configs
    local compose_cmd
    compose_cmd=$(get_compose_cmd)
    local compose_file
    compose_file=$(get_compose_file)
    local svc="${1:-}"

    $compose_cmd --env-file "$ENV_FILE" -f "$compose_file" logs -f ${svc:+"$svc"}
}

cmd_dokploy_export() {
    local dokploy_file="${COMPOSE_DIR}/docker-compose.dokploy.yml"
    if [ -f "$dokploy_file" ]; then
        cat "$dokploy_file"
    else
        die "Файл ${dokploy_file} не найден."
    fi
}

cmd_dokploy_traefik() {
    load_config_data_safe "$ENV_FILE" 2>/dev/null || true
    local py_script="${SCRIPT_DIR}/src/panel/dokploy_traefik.py"
    [ -f "$py_script" ] || py_script="${SCRIPT_DIR}/dokploy_traefik.py"
    local py_bin="python3"
    if command -v python >/dev/null 2>&1 && python -c "import sys" >/dev/null 2>&1; then
        py_bin="python"
    elif command -v python3 >/dev/null 2>&1; then
        py_bin="python3"
    fi
    if [ -f "$py_script" ]; then
        "$py_bin" "$py_script" --domain "${PRIMARY_DOMAIN:-example.com}" \
            --panel-port "${PANEL_PORT:-10443}" \
            --sub-port "${SUB_PORT:-55443}" \
            --xhttp-port "${XHTTP_STREAM_PORT:-50443}"
    else
        die "Скрипт генератора Traefik не найден: $py_script"
    fi
}

cmd_clients() {
    ensure_configs
    # Чтение переменных из .env
    load_config_data_safe "$ENV_FILE" || die "Ошибка загрузки конфигурации из $ENV_FILE"

    local dom="${PRIMARY_DOMAIN:-yourdomain.online}"
    local m_port="${MASQUE_PORT:-8449}"
    local m_user="${MASQUE_USER:-client}"
    local m_pass="${MASQUE_PASS:-password}"
    local stls_port="${SHADOWTLS_PORT:-8543}"
    local stls_pass="${SHADOWTLS_PASSWORD:-password}"
    local stls_sni="${SHADOWTLS_SNI:-gateway.icloud.com}"
    local ss_port="${SS2022_BACKEND_PORT:-8388}"
    local naive_port="${NAIVE_PORT:-8446}"
    local naive_dom="${NAIVE_DOMAIN:-naive.$dom}"
    local naive_user="${NAIVE_USER:-naiveuser}"
    local naive_pass="${NAIVE_PASS:-password}"
    local ws_dom="${WSTUNNEL_DOMAIN:-wstunnel.$dom}"

    echo ""
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${CYAN}  КЛИЕНТСКИЕ КОНФИГУРАЦИИ СЛЕДУЮЩЕГО ПОКОЛЕНИЯ & DOKPLOY    ${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo ""

    # 1. MASQUE (Sing-box Outbound)
    echo -e "${BOLD}${YELLOW}1. MASQUE (RFC 9484 / RFC 9298 HTTP/3 Datagram)${NC}"
    echo -e "   Клиенты: ${CYAN}Sing-box 1.14+, Happ Proxy, FoXray, iOS 17+ Network.framework${NC}"
    echo -e "   Конфиг Sing-box (outbound JSON):"
    cat << EOF_MASQUE
{
  "type": "masque",
  "tag": "masque-out",
  "server": "${dom}",
  "server_port": ${m_port},
  "username": "${m_user}",
  "password": "${m_pass}",
  "tls": {
    "enabled": true,
    "server_name": "${dom}",
    "alpn": ["h3"]
  },
  "connect_udp": {
    "enabled": true,
    "uri_template": "/.well-known/masque/udp/{target_host}/{target_port}/"
  }
}
EOF_MASQUE
    echo ""

    # 2. ShadowTLS v4 + Shadowsocks-2022 (with udp_over_tcp)
    echo -e "${BOLD}${YELLOW}2. ShadowTLS v4 + Shadowsocks-2022 (udp_over_tcp: true)${NC}"
    echo -e "   Клиенты: ${CYAN}Sing-box, Clsh/Mihomo, Shadowrocket, Loon, Surge${NC}"
    echo -e "   Схема подключения: ShadowTLS (${stls_port}/tcp, SNI: ${stls_sni}) -> Shadowsocks-2022 (${ss_port})"
    cat << EOF_STLS
{
  "outbounds": [
    {
      "type": "shadowtls",
      "tag": "shadowtls-out",
      "server": "${dom}",
      "server_port": ${stls_port},
      "version": 3,
      "password": "${stls_pass}",
      "tls": {
        "enabled": true,
        "server_name": "${stls_sni}"
      }
    },
    {
      "type": "shadowsocks",
      "tag": "ss-out",
      "detour": "shadowtls-out",
      "server": "${dom}",
      "server_port": ${stls_port},
      "method": "2022-blake3-aes-128-gcm",
      "password": "YOUR_SS2022_KEY_FROM_3XUI",
      "udp_over_tcp": true
    }
  ]
}
EOF_STLS
    echo ""

    # 3. NaïveProxy (Caddy)
    echo -e "${BOLD}${YELLOW}3. NaïveProxy (Chromium Network Stack Camouflage)${NC}"
    echo -e "   Клиенты: ${CYAN}NaïveProxy CLI, Sing-box, NekoBox, Clash Meta${NC}"
    echo -e "   URL подключения: ${GREEN}naive+https://${naive_user}:${naive_pass}@${naive_dom}:${naive_port}${NC}"
    echo ""

    # 4. Wstunnel over Dokploy Traefik
    echo -e "${BOLD}${YELLOW}4. Wstunnel over Dokploy Traefik (WebSocket / HTTP/3 over port 443)${NC}"
    echo -e "   Туннелирование WireGuard / AmneziaWG через Dokploy Traefik:"
    echo -e "   Команда запуска клиента wstunnel на ПК / роутере:"
    echo -e "   ${GREEN}wstunnel client -L udp://127.0.0.1:51820:host.docker.internal:51820 wss://${ws_dom}${NC}"
    echo -e "   (В клиенте WireGuard/AmneziaWG укажите Endpoint = 127.0.0.1:51820)"
    echo -e "   ${DIM}Примечание: host.docker.internal перенаправляет трафик из контейнера wstunnel на хост-сервис WireGuard.${NC}"
    echo ""

    # 5. Server-Side Zapret
    echo -e "${BOLD}${YELLOW}5. Server-Side Zapret (DPI Desynchronization)${NC}"
    echo -e "   Работает прозрачно на сервере через ${CYAN}iptables NFQUEUE connbytes 1:6${NC}."
    echo -e "   На стороне клиента дополнительных настроек не требуется."
    echo ""
}

case "${1:-status}" in
    status)
        cmd_status
        ;;
    up)
        acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "manage-services-up" || exit $?
        cmd_up "${2:-}"
        ;;
    down)
        acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "manage-services-down" || exit $?
        cmd_down "${2:-}"
        ;;
    restart)
        acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "manage-services-restart" || exit $?
        cmd_restart "${2:-}"
        ;;
    logs)
        cmd_logs "${2:-}"
        ;;
    dokploy-export)
        cmd_dokploy_export
        ;;
    dokploy-traefik)
        cmd_dokploy_traefik
        ;;
    clients)
        cmd_clients
        ;;
    *)
        echo "Использование: $0 {status|up|down|restart|logs|clients|dokploy-export|dokploy-traefik} [service]"
        exit 1
        ;;
esac
