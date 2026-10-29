#!/usr/bin/env bash
# ==============================================================================
#  CONFIGURE 3X-UI INBOUNDS & SETTINGS (v9.7.0 Universal Companion & Smart Reconcile)
# ==============================================================================
#  Скрипт автоматического конфигурирования и самовосстановления базы 3X-UI.
#  Безопасен для повторного запуска:
#    1. Сохранение существующих клиентов (UUID, пароли Hy2, ключи AWG, лимиты);
#    2. Сохранение действующих серверных ключей REALITY и AmneziaWG;
#    3. Самоисправление скрытых ошибок (reality settings.publicKey, мертвый SNI swdist);
#    4. Автоматическая настройка externalProxy :443 для корректных ссылок подписок;
#    5. Защита существующей кастомной подписки (не затирает кастомный домен/путь);
#    6. Режим безопасного аудита (--dry-run) и авто-бэкап базы перед записью.
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
die()  {
    echo -e "  ${RED}${CROSS:-✖} $*${NC}" >&2
    if is_true "${DEBUG_MODE:-0}" && command -v offer_debug_log_export >/dev/null 2>&1; then
        offer_debug_log_export || true
    fi
    exit 1
}
#!/usr/bin/env bash
# ==============================================================================
# src/system/service.sh — Unified Service Manager & OS Abstraction Layer
# ==============================================================================
# Transparently abstracts service management between systemd and OpenRC.
# Ensures 100% native execution on Alpine Linux while preserving full
# backward compatibility with Ubuntu / Debian.
# ==============================================================================

is_openrc() {
    if [ -f /sbin/openrc-run ] || [ -f /etc/init.d/rc ] || [ -f /etc/alpine-release ]; then
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        return 0
    fi
    if [ -f /etc/os-release ]; then
        local os_id=""
        os_id=$(. /etc/os-release 2>/dev/null; echo "${ID:-}")
        if [ "$os_id" = "alpine" ] && ! command -v systemctl >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

is_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

svc_daemon_reload() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

svc_start() {
    local name="$1"
    if is_openrc; then
        rc-service "$name" start
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl start "$name"
    elif [ -x "/etc/init.d/$name" ]; then
        "/etc/init.d/$name" start
    else
        return 1
    fi
}

svc_stop() {
    local name="$1"
    if is_openrc; then
        rc-service "$name" stop
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl stop "$name"
    elif [ -x "/etc/init.d/$name" ]; then
        "/etc/init.d/$name" stop
    else
        return 1
    fi
}

svc_restart() {
    local name="$1"
    if is_openrc; then
        rc-service "$name" restart
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl restart "$name"
    elif [ -x "/etc/init.d/$name" ]; then
        "/etc/init.d/$name" restart
    else
        return 1
    fi
}

svc_reload() {
    local name="$1"
    if is_openrc; then
        rc-service "$name" reload 2>/dev/null || rc-service "$name" restart
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl reload "$name" 2>/dev/null || systemctl restart "$name"
    elif [ -x "/etc/init.d/$name" ]; then
        "/etc/init.d/$name" reload 2>/dev/null || "/etc/init.d/$name" restart
    else
        return 1
    fi
}

svc_enable() {
    local name="$1"
    if is_openrc; then
        rc-update add "$name" default >/dev/null 2>&1 || true
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl enable "$name" >/dev/null 2>&1 || true
    fi
}

svc_disable() {
    local name="$1"
    if is_openrc; then
        rc-update del "$name" default >/dev/null 2>&1 || rc-update del "$name" >/dev/null 2>&1 || true
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl disable "$name" >/dev/null 2>&1 || true
    fi
}

svc_is_active() {
    local name="$1"
    if is_openrc; then
        rc-service "$name" status >/dev/null 2>&1
    elif command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet "$name" 2>/dev/null
    elif [ -x "/etc/init.d/$name" ]; then
        "/etc/init.d/$name" status >/dev/null 2>&1
    else
        return 1
    fi
}

svc_create_daemon() {
    local name="$1"
    local desc="$2"
    local cmd="$3"
    local args="${4:-}"
    local respawn_delay="${5:-3}"
    local pre_start="${6:-}"
    local post_stop="${7:-}"
    local user="${8:-}"
    local group="${9:-}"

    if is_openrc; then
        mkdir -p /etc/init.d /run/openrc 2>/dev/null || true
        touch /run/openrc/softlevel 2>/dev/null || true
        local init_file="/etc/init.d/${name}"

        {
            echo "#!/sbin/openrc-run"
            echo "description=\"${desc}\""
            echo "supervisor=\"supervise-daemon\""
            echo "command=\"${cmd}\""
            [ -n "${args}" ] && echo "command_args=\"${args}\""
            echo "pidfile=\"/run/\${RC_SVCNAME}.pid\""
            echo "respawn_delay=${respawn_delay}"
            echo "respawn_max=5"
            [ -n "${user}" ] && echo "command_user=\"${user}${group:+:$group}\""
            echo ""
            if [ -n "${pre_start}" ]; then
                echo "start_pre() {"
                echo "    ${pre_start}"
                echo "}"
                echo ""
            fi
            if [ -n "${post_stop}" ]; then
                echo "stop_post() {"
                echo "    ${post_stop}"
                echo "}"
                echo ""
            fi
            echo "depend() {"
            echo "    need net"
            echo "    after firewall"
            echo "}"
        } > "$init_file"

        chmod 755 "$init_file"
    else
        mkdir -p /etc/systemd/system 2>/dev/null || true
        local unit_file="/etc/systemd/system/${name}.service"

        {
            echo "[Unit]"
            echo "Description=${desc}"
            echo "After=network.target network-online.target"
            echo "Wants=network-online.target"
            echo ""
            echo "[Service]"
            echo "Type=simple"
            [ -n "${user}" ] && echo "User=${user}"
            [ -n "${group}" ] && echo "Group=${group}"
            if [ -n "${pre_start}" ]; then
                # Split multiple commands if delimited by semicolon or emit as is
                echo "ExecStartPre=${pre_start}"
            fi
            echo "ExecStart=${cmd}${args:+ $args}"
            if [ -n "${post_stop}" ]; then
                echo "ExecStopPost=${post_stop}"
            fi
            echo "Restart=always"
            echo "RestartSec=${respawn_delay}s"
            echo "LimitNOFILE=65535"
            echo ""
            echo "[Install]"
            echo "WantedBy=multi-user.target"
        } > "$unit_file"

        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
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
normalize_node_token_config() {
    local enabled="${CLI_ENABLE_NODE_TOKEN:-${ENABLE_NODE_TOKEN:-y}}"
    NODE_TOKEN="${NODE_TOKEN:-}"
    NODE_TOKEN_NAME="${CLI_NODE_TOKEN_NAME:-${NODE_TOKEN_NAME:-}}"
    NODE_TOKEN_SCOPE="${CLI_NODE_TOKEN_SCOPE:-${NODE_TOKEN_SCOPE:-node-sync}}"
    case "${NODE_TOKEN_SCOPE,,}" in
        admin) NODE_TOKEN_SCOPE="admin" ;;
        node-admin) NODE_TOKEN_SCOPE="node-admin" ;;
        *) NODE_TOKEN_SCOPE="node-sync" ;;
    esac
    case "${enabled,,}" in y|1|true) ENABLE_NODE_TOKEN=y ;; *) ENABLE_NODE_TOKEN=n; return 0 ;; esac
    case "${AUTO_SETUP_3XUI:-y}" in n|0|false) ENABLE_NODE_TOKEN=n; return 0 ;; esac
    if [ -z "$NODE_TOKEN_NAME" ]; then
        local prefix="${SERVER_PREFIX-Server}"
        case "${prefix,,}" in
            ''|-|none|off|no) NODE_TOKEN_NAME=Master-Node-Cluster ;;
            *)
                local clean_p
                clean_p=$(printf '%s' "$prefix" | tr -cd 'a-zA-Z0-9_-')
                [ -n "$clean_p" ] || clean_p="Server"
                NODE_TOKEN_NAME="${clean_p}-Node"
                ;;
        esac
    fi
}

node_token_runtime_file() {
    if [ -n "${NODE_ENV_FILE:-}" ]; then printf '%s' "$NODE_ENV_FILE";
    elif [ -d /run ]; then printf '/run/3xui_node_token.env';
    else printf '/tmp/3xui_node_token.env'; fi
}

load_node_token_result() {
    local file="$1" line key value
    NODE_TOKEN=""
    [ -f "$file" ] || return 1
    local double_quote='^"(.*)"$' single_quote="^'(.*)'\$"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^(NODE_TOKEN_NAME|NODE_TOKEN|NODE_TOKEN_SCOPE)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        if [[ "$value" =~ $double_quote ]] || [[ "$value" =~ $single_quote ]]; then value="${BASH_REMATCH[1]}"; fi
        printf -v "$key" '%s' "$value"
    done < "$file"
    [ -n "${NODE_TOKEN:-}" ]
}

node_token_operation() {
    "$PYTHON_CMD" - "$@" <<'EOF_NODE_TOKEN_PY'
"""Local node-token lifecycle for the 3X-UI API-token SQLite schema."""
from contextlib import closing
import hashlib
import hmac
import os
from pathlib import Path
import secrets
import sqlite3
import sys
import tempfile
import time


def connect(path):
    return sqlite3.connect(Path(path).resolve().as_uri() + "?mode=rw", uri=True, timeout=10)


def verify(path, name, token, required_scope=None):
    if not token:
        return False
    try:
        with closing(connect(path)) as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute("SELECT * FROM api_tokens WHERE name=?", (name,)).fetchone()
        if row is None or not row["enabled"]:
            return False
        if "expires_at" in row.keys():
            expiry = int(row["expires_at"] or 0)
            if expiry > 100_000_000_000:
                expiry //= 1000
            if expiry and expiry <= int(time.time()):
                return False
        if "scope" in row.keys():
            if row["scope"] not in ("admin", "node-admin", "node-sync"):
                return False
            if required_scope and row["scope"] != required_scope:
                return False
        return hmac.compare_digest(hashlib.sha256(token.encode()).hexdigest(), row["token"])
    except (sqlite3.Error, ValueError, TypeError):
        return False


def create(path, name, scope="node-sync"):
    with closing(connect(path)) as conn, conn:
        columns = {row[1] for row in conn.execute("PRAGMA table_info(api_tokens)")}
        if not {"name", "token", "enabled"} <= columns:
            raise ValueError("Unsupported 3X-UI API-token schema")
        token = secrets.token_hex(32)
        values = {"name": name, "token": hashlib.sha256(token.encode()).hexdigest(), "enabled": 1}
        target_scope = scope if scope else "node-sync"
        scope_map = {
            "node-sync": ("scope", "node-sync"),
            "node-admin": ("scope", "node-admin"),
            "admin": ("scope", "admin"),
        }
        scope_entry = scope_map.get(target_scope, ("scope", target_scope))
        for column, value in (scope_entry, ("created_at", int(time.time())), ("expires_at", 0)):
            if column in columns:
                values[column] = value
        if conn.execute("SELECT 1 FROM api_tokens WHERE name=?", (name,)).fetchone():
            update = {key: value for key, value in values.items() if key != "name"}
            conn.execute("UPDATE api_tokens SET " + ",".join(key + "=?" for key in update) + " WHERE name=?",
                         [*update.values(), name])
        else:
            conn.execute("INSERT INTO api_tokens (" + ",".join(values) + ") VALUES ("
                         + ",".join("?" for _ in values) + ")", list(values.values()))
    return token


def atomic_write(path, text):
    path = Path(path)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def persist(runtime_path, config_path, name, token, scope=None):
    values = {"ENABLE_NODE_TOKEN": "y", "NODE_TOKEN_NAME": name, "NODE_TOKEN": token}
    if scope:
        values["NODE_TOKEN_SCOPE"] = scope
    if any("\n" in value or "\r" in value for value in values.values()):
        raise ValueError("Node-token values must be single-line strings")
    # These files are read as literal KEY=value data, never evaluated as shell code.
    lines = [f'{key}="{value}"' for key, value in values.items()]
    atomic_write(runtime_path, "\n".join(lines) + "\n")
    if config_path and Path(config_path).is_file():
        previous = Path(config_path).read_text(encoding="utf-8").splitlines()
        previous = [line for line in previous if line.partition("=")[0] not in values]
        atomic_write(config_path, "\n".join([*previous, *lines]) + "\n")


def main(args):
    action, *values = args
    if action == "verify":
        return 0 if verify(*values) else 1
    if action == "create":
        print(create(*values))
    elif action == "persist":
        persist(*values)
    else:
        raise ValueError("Unknown node-token operation")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, ValueError, sqlite3.Error) as error:
        print(f"Node API token: {error}", file=sys.stderr)
        raise SystemExit(1)
EOF_NODE_TOKEN_PY
}

ensure_node_token() {
    case "${ENABLE_NODE_TOKEN:-y}" in n|0|false) return 0 ;; esac
    NODE_TOKEN="${NODE_TOKEN:-}"
    local target_scope="${NODE_TOKEN_SCOPE:-node-sync}"
    case "${target_scope,,}" in
        admin) target_scope="admin" ;;
        node-admin) target_scope="node-admin" ;;
        *) target_scope="node-sync" ;;
    esac

    if node_token_operation verify "$DB_PATH" "$NODE_TOKEN_NAME" "$NODE_TOKEN"; then
        ok "Действующий API-ключ ноды '$NODE_TOKEN_NAME' сохранён."
    else
        NODE_TOKEN=""
        local token_out="" attempt
        local -a arguments=()
        if [ -n "${XUI_BIN:-}" ]; then
            for attempt in 1 2 3; do
                case "$attempt" in
                    1) arguments=(-tokenName "$NODE_TOKEN_NAME" -tokenScope "$target_scope") ;;
                    2)
                        # Fallback if 3X-UI version does not support node-sync for -tokenScope
                        if [ "$target_scope" != "admin" ]; then
                            arguments=(-tokenName "$NODE_TOKEN_NAME" -tokenScope admin)
                        else
                            arguments=(-tokenName "$NODE_TOKEN_NAME")
                        fi
                        ;;
                    3) arguments=(-tokenName "$NODE_TOKEN_NAME") ;;
                esac
                token_out=$("$XUI_BIN" setting -getApiToken "${arguments[@]}" 2>&1 || true)
                NODE_TOKEN=$(printf '%s\n' "$token_out" | awk '$1 == "apiToken:" {gsub(/\r/, "", $2); print $2; exit}')
                [ -z "$NODE_TOKEN" ] || break
            done
        fi
        # Also handles CLI versions without named-token flags, without renaming other tokens.
        if ! node_token_operation verify "$DB_PATH" "$NODE_TOKEN_NAME" "$NODE_TOKEN"; then
            NODE_TOKEN=$(node_token_operation create "$DB_PATH" "$NODE_TOKEN_NAME" "$target_scope") || die "Не удалось создать API-ключ ноды 3X-UI."
        fi
        [ -n "$NODE_TOKEN" ] || die "3X-UI не вернул API-ключ ноды."
        local scope_title="Синхронизация узла"
        [ "$target_scope" = "admin" ] && scope_title="Администратор"
        ok "API-ключ ноды '$NODE_TOKEN_NAME' создан (область доступа: $scope_title)."
    fi
    local runtime_file
    runtime_file=$(node_token_runtime_file)
    node_token_operation persist "$runtime_file" "${CONFIG_FILE:-}" "$NODE_TOKEN_NAME" "$NODE_TOKEN" "$target_scope" || die "Не удалось сохранить API-ключ ноды."
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

run_backup_engine() {
    local py_cmd
    py_cmd=$(get_sqlite_backup_python || return 1)
    local script_loc=""
    for cand in \
        "$(dirname "${BASH_SOURCE[0]:-$0}")/backup_engine.py" \
        "$(dirname "${BASH_SOURCE[0]:-$0}")/../common/backup_engine.py" \
        "$(dirname "${BASH_SOURCE[0]:-$0}")/src/common/backup_engine.py" \
        "${SCRIPT_DIR:-.}/src/common/backup_engine.py" \
        "${SCRIPT_DIR:-.}/backup_engine.py"; do
        if [ -f "$cand" ]; then
            script_loc="$cand"
            break
        fi
    done
    if [ -n "$script_loc" ]; then
        "$py_cmd" "$script_loc" "$@"
        return $?
    fi
    "$py_cmd" - "$@" << 'EOF_BACKUP_ENGINE'
"""
src/common/backup_engine.py - Unified Backup & Verification Engine.

Structured Python engine for SQLite WAL-safe live backups, integrity verification,
SHA-256 backup manifest generation/verification, and secure tarfile archive handling.
"""

import hashlib
import json
import os
import sqlite3
import sys
import tarfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Union


def _sha256_file(file_path: Union[str, Path]) -> Optional[str]:
    """Calculate SHA-256 digest of a file in memory-efficient 64KB chunks."""
    h = hashlib.sha256()
    try:
        with open(str(file_path), "rb") as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None


def verify_db(db_path: Union[str, Path]) -> bool:
    """Verify SQLite database integrity using PRAGMA integrity_check."""
    p = str(db_path)
    if not os.path.isfile(p) or os.path.getsize(p) == 0:
        return False
    conn = None
    try:
        abs_p = os.path.abspath(p)
        try:
            conn = sqlite3.connect(f"file:{abs_p}?mode=ro", uri=True, timeout=10.0)
        except Exception:
            conn = sqlite3.connect(p, timeout=10.0)
        res = conn.execute("PRAGMA integrity_check;").fetchall()
        return bool(res and res[0][0] == "ok")
    except Exception:
        return False
    finally:
        if conn:
            try:
                conn.close()
            except Exception:
                pass


def backup_db(src_path: Union[str, Path], dst_path: Union[str, Path]) -> bool:
    """Perform atomic, WAL-safe online backup of an SQLite database."""
    src_p = str(src_path)
    dst_p = str(dst_path)

    if not os.path.isfile(src_p):
        return False

    # Ensure parent directory for destination exists
    dst_dir = os.path.dirname(os.path.abspath(dst_p))
    if dst_dir:
        os.makedirs(dst_dir, exist_ok=True)

    src_conn = None
    dst_conn = None
    try:
        try:
            src_conn = sqlite3.connect(f"file:{src_p}?mode=ro", uri=True, timeout=10.0)
        except Exception:
            src_conn = sqlite3.connect(src_p, timeout=10.0)

        dst_conn = sqlite3.connect(dst_p, timeout=10.0)
        with dst_conn:
            src_conn.backup(dst_conn)
        dst_conn.close()
        dst_conn = None
        src_conn.close()
        src_conn = None

        return verify_db(dst_p)
    except Exception:
        try:
            if os.path.exists(dst_p):
                os.remove(dst_p)
        except OSError:
            pass
        return False
    finally:
        if dst_conn:
            try:
                dst_conn.close()
            except Exception:
                pass
        if src_conn:
            try:
                src_conn.close()
            except Exception:
                pass


def create_manifest(staging_dir: Union[str, Path], output_path: Optional[Union[str, Path]] = None) -> bool:
    """Generate manifest.json with SHA-256 hashes of all files in staging directory."""
    staging = str(staging_dir)
    manifest_path = str(output_path) if output_path else os.path.join(staging, "manifest.json")
    files_map: Dict[str, str] = {}

    for root, _, files in os.walk(staging):
        for f in sorted(files):
            if f == "manifest.json":
                continue
            full_p = os.path.join(root, f)
            rel_p = os.path.relpath(full_p, staging).replace("\\", "/")
            h = _sha256_file(full_p)
            if h is not None:
                files_map[rel_p] = h

    created_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    data = {
        "format_version": "2.0",
        "project_version": os.environ.get("SCRIPT_VERSION", "v9.7.0"),
        "created_at": created_iso,
        "db_path": os.environ.get("DB_PATH", "/etc/x-ui/x-ui.db"),
        "files": files_map,
    }

    try:
        with open(manifest_path, "w", encoding="utf-8") as out:
            json.dump(data, out, indent=2)
        return True
    except Exception:
        return False


def verify_manifest(staging_dir: Union[str, Path], manifest_path: Optional[Union[str, Path]] = None) -> bool:
    """Verify integrity of backed up files against manifest.json with path traversal protection."""
    staging = str(staging_dir)
    man_p = str(manifest_path) if manifest_path else os.path.join(staging, "manifest.json")

    if not os.path.isfile(man_p):
        print(f"[ERROR] Manifest file not found: {man_p}", file=sys.stderr)
        return False

    try:
        with open(man_p, "r", encoding="utf-8") as fp:
            manifest = json.load(fp)
    except Exception as e:
        print(f"[ERROR] Failed to parse manifest {man_p}: {e}", file=sys.stderr)
        return False

    staging_real = os.path.realpath(staging)

    for rel_p, expected_h in manifest.get("files", {}).items():
        # Security: reject entries attempting path traversal or absolute references
        norm_rel = rel_p.replace("\\", "/")
        if os.path.isabs(norm_rel) or norm_rel.startswith("/") or ".." in norm_rel.split("/"):
            print(f"[ERROR] Path traversal detected in manifest entry: {rel_p}", file=sys.stderr)
            return False

        full_p = os.path.realpath(os.path.join(staging, rel_p))
        if not full_p.startswith(staging_real + os.sep) and full_p != staging_real:
            print(f"[ERROR] Manifest entry escapes staging directory: {rel_p}", file=sys.stderr)
            return False

        if not os.path.isfile(full_p):
            print(f"[ERROR] Missing backed up file: {rel_p}", file=sys.stderr)
            return False

        actual_h = _sha256_file(full_p)
        if actual_h is None or actual_h != expected_h:
            print(f"[ERROR] Checksum mismatch for {rel_p}: expected {expected_h}, got {actual_h}", file=sys.stderr)
            return False

    return True


def create_archive(archive_path: Union[str, Path], staging_dir: Union[str, Path]) -> bool:
    """Create gzip-compressed tar archive from items in staging directory."""
    archive = str(archive_path)
    staging = str(staging_dir)

    try:
        with tarfile.open(archive, "w:gz") as tar:
            for item in sorted(os.listdir(staging)):
                tar.add(os.path.join(staging, item), arcname=item)
        return True
    except Exception as e:
        print(f"[ERROR] Failed to create tar archive {archive}: {e}", file=sys.stderr)
        return False


def extract_archive(archive_path: Union[str, Path], target_dir: Union[str, Path]) -> bool:
    """Safely extract gzip-compressed tar archive with path traversal protection."""
    archive = str(archive_path)
    target = str(target_dir)

    os.makedirs(target, exist_ok=True)
    dest = os.path.realpath(target)

    try:
        with tarfile.open(archive, "r:gz") as tar:
            if hasattr(tarfile, "data_filter"):
                tar.extractall(target, filter="data")
            else:
                for m in tar.getmembers():
                    mp = os.path.realpath(os.path.join(dest, m.name))
                    if not mp.startswith(dest + os.sep) and mp != dest:
                        raise RuntimeError(f"Path Traversal detected: {m.name}")
                    if m.islnk() or m.issym():
                        continue
                    tar.extract(m, dest)
        return True
    except Exception as e:
        print(f"[ERROR] Failed to safely extract archive {archive}: {e}", file=sys.stderr)
        return False


def main(argv: Optional[List[str]] = None) -> int:
    """CLI dispatcher for backup engine operations."""
    if argv is None:
        argv = sys.argv[1:]
    if not argv:
        print("Usage: backup_engine.py <command> [args...]", file=sys.stderr)
        return 1

    cmd = argv[0]
    if cmd == "backup_db":
        if len(argv) < 3:
            print("Usage: backup_engine.py backup_db <src> <dst>", file=sys.stderr)
            return 1
        return 0 if backup_db(argv[1], argv[2]) else 1
    elif cmd == "verify_db":
        if len(argv) < 2:
            print("Usage: backup_engine.py verify_db <db_path>", file=sys.stderr)
            return 1
        return 0 if verify_db(argv[1]) else 1
    elif cmd == "create_manifest":
        if len(argv) < 2:
            print("Usage: backup_engine.py create_manifest <staging_dir> [manifest_path]", file=sys.stderr)
            return 1
        out_p = argv[2] if len(argv) > 2 else None
        return 0 if create_manifest(argv[1], out_p) else 1
    elif cmd == "verify_manifest":
        if len(argv) < 2:
            print("Usage: backup_engine.py verify_manifest <staging_dir> [manifest_path]", file=sys.stderr)
            return 1
        man_p = argv[2] if len(argv) > 2 else None
        return 0 if verify_manifest(argv[1], man_p) else 1
    elif cmd == "create_archive":
        if len(argv) < 3:
            print("Usage: backup_engine.py create_archive <archive_path> <staging_dir>", file=sys.stderr)
            return 1
        return 0 if create_archive(argv[1], argv[2]) else 1
    elif cmd == "extract_archive":
        if len(argv) < 3:
            print("Usage: backup_engine.py extract_archive <archive_path> <target_dir>", file=sys.stderr)
            return 1
        return 0 if extract_archive(argv[1], argv[2]) else 1
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
EOF_BACKUP_ENGINE
}

verify_sqlite_backup() {
    local bkp="$1"
    local py_cmd="${2:-}"
    if [ ! -s "$bkp" ]; then
        return 1
    fi
    if [ -n "$py_cmd" ] || get_sqlite_backup_python >/dev/null 2>&1; then
        run_backup_engine verify_db "$bkp" 2>/dev/null && return 0
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
        if run_backup_engine backup_db "$src" "$dst" 2>/dev/null; then
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
        if command -v load_config_data_safe >/dev/null 2>&1; then
            load_config_data_safe "$cfg" 2>/dev/null || true
        fi
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
    run_backup_engine create_manifest "$staging" 2>/dev/null || true

    # 9. Упаковка архива
    if ! run_backup_engine create_archive "$archive" "$staging"; then
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
    if ! run_backup_engine extract_archive "$archive" "$staging"; then
        rm -rf "$staging"
        die "Ошибка безопасной распаковки архива $archive."
    fi

    # 0. Проверка целостности файлов бэкапа по manifest.json (T21.C01, T21.C02)
    if [ -f "$staging/manifest.json" ]; then
        if ! run_backup_engine verify_manifest "$staging"; then
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

    if ! run_backup_engine extract_archive "$archive" "$target"; then
        die "Ошибка извлечения архива $archive."
    fi
    ok "Архив $archive успешно и безопасно извлечён в $target"
    return 0
}

audit_restore_archive() {
    local archive="${1:-}"
    [[ -n "$archive" ]] || die "Укажите путь к архиву: ./maintain.sh --dry-run restore <архив.tar.gz>"
    [[ -f "$archive" ]] || die "Файл архива не найден: $archive"

    local staging
    staging=$(mktemp -d /tmp/vpn-audit-staging.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/vpn-audit-staging.XXXXXX") || die "Не удалось создать временный каталог для аудита."

    if ! run_backup_engine extract_archive "$archive" "$staging"; then
        rm -rf "$staging"
        die "Ошибка распаковки архива $archive при аудите."
    fi

    # 1. Проверка манифеста (T21.C01, T21.C02)
    if [ -f "$staging/manifest.json" ]; then
        if ! run_backup_engine verify_manifest "$staging"; then
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

# Execute in a fresh Bash so a caller's `if`/`||` cannot suppress errexit.
# A private snapshot preserves Bash functions and unexported variables in both modes.
execute_install_task() (
    umask 077
    task_dir=$(mktemp -d "${TMPDIR:-/tmp}/server-task.XXXXXX") || exit 1
    trap 'rm -f -- "$task_dir/task.sh"; rmdir -- "$task_dir"' EXIT
    {
        declare -p | grep -vE '^declare -[^ ]*r|^declare [^ ]+ (BASH[^ =]*|FUNCNAME|DIRSTACK|GROUPS|PIPESTATUS|LINENO|RANDOM|SRANDOM|SECONDS|EPOCHSECONDS|EPOCHREALTIME|_)='
        declare -f
        cat << 'EOF_TASK_TRAP'
__task_err_handler() {
    local ec=$?
    local cmd="${BASH_COMMAND:-unknown}"
    local line="${BASH_LINENO[0]:-unknown}"
    local fn="${FUNCNAME[1]:-main}"
    printf '\n[ERROR-TRACE] Сбой команды: %s (строка: %s, функция: %s, код: %s)\n' "$cmd" "$line" "$fn" "$ec" >&2
}
trap '__task_err_handler' ERR
EOF_TASK_TRAP
        printf '%s\n' 'shopt -s inherit_errexit 2>/dev/null || true' 'set -Eeuo pipefail' '"$@"'
    } > "$task_dir/task.sh" || exit 1
    bash --noprofile --norc "$task_dir/task.sh" "$@"
)

# Инициализация единого системного журнала установки
init_server_setup_log() {
    if [ -n "${SERVER_SETUP_LOG:-}" ]; then
        return 0
    fi
    local cand
    for cand in "${TARGET_ROOT:-}/var/log/server-setup.log" \
                "${TMPDIR:-/tmp}/server-setup.log"; do
        [ -n "$cand" ] || continue
        local pdir
        pdir="$(dirname "$cand" 2>/dev/null || echo ".")"
        if [ -d "$pdir" ] && [ -w "$pdir" ]; then
            SERVER_SETUP_LOG="$cand"
            break
        fi
    done
    [ -n "${SERVER_SETUP_LOG:-}" ] || SERVER_SETUP_LOG="${TMPDIR:-/tmp}/server-setup.log"
    if [ ! -f "$SERVER_SETUP_LOG" ]; then
        touch "$SERVER_SETUP_LOG" 2>/dev/null && chmod 600 "$SERVER_SETUP_LOG" 2>/dev/null || true
    fi
}

# Извлечение журналов systemd при сбое служб
get_systemd_diagnostic_logs() {
    command -v journalctl >/dev/null 2>&1 || return 0
    [ -d /run/systemd/system ] || return 0

    local diag=""
    if command -v systemctl >/dev/null 2>&1; then
        local failed_units
        failed_units=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' || true)
        if [ -n "$failed_units" ]; then
            diag="${diag}  [systemd: аварийные службы]: ${failed_units}"$'\n'
            for u in $failed_units; do
                local u_logs
                u_logs=$(journalctl -u "$u" -n 15 --no-pager 2>/dev/null || true)
                if [ -n "$u_logs" ]; then
                    diag="${diag}  --- journalctl -u ${u} (последние 15 строк) ---"$'\n'
                    diag="${diag}$(echo "$u_logs" | sed 's/^/    /')"$'\n'
                fi
            done
        fi
    fi

    if [ -z "$diag" ]; then
        local recent_errs
        recent_errs=$(journalctl --since "1 minute ago" -p err..emerg --no-pager -n 15 2>/dev/null || true)
        if [ -n "$recent_errs" ]; then
            diag="${diag}  --- Системные ошибки journalctl (за последнюю минуту) ---"$'\n'
            diag="${diag}$(echo "$recent_errs" | sed 's/^/    /')"$'\n'
        fi
    fi

    if [ -n "$diag" ]; then
        echo -e "\n  ${YELLOW}${BOLD}Диагностика системных служб (journalctl):${NC}"
        echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
        echo "$diag"
        echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
    fi
}

# Interactive Terminal Spinner & Task Runner
# Supports:
#   - Animated spinner in interactive TTY
#   - Plain output in non-interactive / CI / piped runs
#   - Smart Implicit Debug: full output and ERR-traces captured automatically
#   - Explicit DEBUG_MODE=1 passthrough (full stdout/stderr in real-time)
#   - Required tasks support Retry / Abort; failures cannot be marked as success

run_with_spinner() {
    local task_name="$1"
    shift
    init_server_setup_log

    local log_file="${SPINNER_LOG_FILE:-}"
    local temporary_log=0
    if [ -z "$log_file" ]; then
        log_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/server-task-log.XXXXXX") || return 1
        temporary_log=1
    fi

    while true; do
        local exit_code=0
        local task_start_ts
        task_start_ts="$(date -u +"%Y-%m-%d %H:%M:%SZ" 2>/dev/null || date)"
        printf "\n[%s] === START TASK: %s ===\n" "$task_start_ts" "$task_name" >> "$SERVER_SETUP_LOG" 2>/dev/null || true

        # ── DEBUG MODE: трансляция в реальном времени с одновременной записью в лог ──
        if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
            echo -e "\n  ${CYAN}[DEBUG]${NC} ${WHITE}▶ $task_name${NC}"
            echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            (umask 077; : > "$log_file") || true
            chmod 600 "$log_file" 2>/dev/null || true

            local prev_e="0"
            case "$-" in *e*) prev_e="1" ;; esac
            set +e
            execute_install_task "$@" 2>&1 | tee -a "$log_file"
            exit_code=${PIPESTATUS[0]}
            if [ "$prev_e" = "1" ]; then set -e; fi

            if [ -s "$log_file" ] && [ -f "$SERVER_SETUP_LOG" ]; then
                cat "$log_file" >> "$SERVER_SETUP_LOG" 2>/dev/null || true
            fi
            printf "[%s] === END TASK: %s (exit: %s) ===\n" "$(date -u +"%Y-%m-%d %H:%M:%SZ" 2>/dev/null || date)" "$task_name" "$exit_code" >> "$SERVER_SETUP_LOG" 2>/dev/null || true

            if [ $exit_code -eq 0 ]; then
                echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
                echo -e "  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}$task_name${NC} ${GREEN}[ГОТОВО]${NC}\n"
                [ "$temporary_log" -eq 0 ] || rm -f -- "$log_file"
                return 0
            else
                echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
                get_systemd_diagnostic_logs
                echo -e "  ${DIM}Полный журнал выполнения: ${WHITE}${SERVER_SETUP_LOG}${NC}\n"
            fi
        else
            # ── Нормальный режим («Умный неявный Debug»): спиннер + фоновая запись ──
            local spin_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
            local delay=0.08

            (umask 077; : > "$log_file") || return 1
            chmod 600 "$log_file" || return 1

            execute_install_task "$@" >> "$log_file" 2>&1 &
            local pid=$!

            if [ ! -t 1 ]; then
                echo -e "  ${CYAN}*${NC}  ${WHITE}${task_name}...${NC}"
                if wait "$pid"; then exit_code=0; else exit_code=$?; fi
            else
                tput civis 2>/dev/null || echo -ne "\033[?25l"
                local i=0
                while kill -0 "$pid" 2>/dev/null; do
                    i=$(( (i + 1) % 10 ))
                    printf "\r  ${CYAN}${spin_chars[$i]}${NC}  ${WHITE}%-54s${NC}" "$task_name..."
                    sleep "$delay"
                done
                if wait "$pid"; then exit_code=0; else exit_code=$?; fi
                tput cnorm 2>/dev/null || echo -ne "\033[?25h"
            fi

            if [ -s "$log_file" ] && [ -f "$SERVER_SETUP_LOG" ]; then
                cat "$log_file" >> "$SERVER_SETUP_LOG" 2>/dev/null || true
            fi
            printf "[%s] === END TASK: %s (exit: %s) ===\n" "$(date -u +"%Y-%m-%d %H:%M:%SZ" 2>/dev/null || date)" "$task_name" "$exit_code" >> "$SERVER_SETUP_LOG" 2>/dev/null || true

            if [ $exit_code -eq 0 ]; then
                if [ ! -t 1 ]; then
                    printf "  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}%-54s${NC} ${GREEN}[ГОТОВО]${NC}\n" "$task_name"
                else
                    printf "\r  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}%-54s${NC} ${GREEN}[ГОТОВО]${NC}\n" "$task_name"
                fi
                [ "$temporary_log" -eq 0 ] || rm -f -- "$log_file"
                return 0
            fi

            if [ ! -t 1 ]; then
                printf "  ${RED}${CROSS:-✖}${NC}  ${WHITE}%-54s${NC} ${RED}[ОШИБКА]${NC}\n" "$task_name"
            else
                printf "\r  ${RED}${CROSS:-✖}${NC}  ${WHITE}%-54s${NC} ${RED}[ОШИБКА]${NC}\n" "$task_name"
            fi
            echo -e "\n  ${RED}${BOLD}Полный лог ошибки:${NC}"
            echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            [ -f "$log_file" ] && cat "$log_file" | sed 's/^/    /' || true
            echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            get_systemd_diagnostic_logs
            echo -e "  ${DIM}Полный журнал выполнения сохранен в: ${WHITE}${SERVER_SETUP_LOG}${NC}\n"
        fi

        # ── Обязательный этап: повторить или прервать ──
        if [ "${NON_INTERACTIVE:-0}" -eq 0 ] && [ -t 1 ]; then
            echo -e "  ${YELLOW}${BOLD}Действия при сбое:${NC}"
            echo -e "    ${CYAN}${BOLD}[1] Повторить попытку (Retry)${NC} — после исправления причин (напр. DNS)"
            echo -e "    ${RED}[2] Прервать установку (Abort)${NC}"
            local retry_ans=""
            read -rp "  Ваш выбор [1/2] (по умолчанию: 1): " retry_ans </dev/tty || read -r retry_ans || retry_ans="1"
            retry_ans=$(echo "${retry_ans:-1}" | tr -d '[:space:]')
            case "$retry_ans" in
                2|3)
                    if command -v offer_debug_log_export >/dev/null 2>&1; then
                        offer_debug_log_export || true
                    fi
                    die "Шаг завершился с ошибкой (exit $exit_code): $task_name"
                    ;;
                *)
                    echo -e "  ${CYAN}${ARROW:-➜} Повторная попытка: $task_name...${NC}\n"
                    continue
                    ;;
            esac
        else
            return $exit_code
        fi
    done
}
#!/usr/bin/env bash
# ==============================================================================
#  PANEL CONFIGURATION ENGINE
# ==============================================================================
#  Automated configuration, self-healing, and inbound reconciliation for 3X-UI.
#  Shared between configure-panel.sh entrypoint and setup.sh (fully autonomous).
# ==============================================================================

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
die()  {
    echo -e "  ${RED}${CROSS:-✖} $*${NC}" >&2
    if is_true "${DEBUG_MODE:-0}" && command -v offer_debug_log_export >/dev/null 2>&1; then
        offer_debug_log_export || true
    fi
    exit 1
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

normalize_node_token_config() {
    local enabled="${CLI_ENABLE_NODE_TOKEN:-${ENABLE_NODE_TOKEN:-y}}"
    NODE_TOKEN="${NODE_TOKEN:-}"
    NODE_TOKEN_NAME="${CLI_NODE_TOKEN_NAME:-${NODE_TOKEN_NAME:-}}"
    NODE_TOKEN_SCOPE="${CLI_NODE_TOKEN_SCOPE:-${NODE_TOKEN_SCOPE:-node-sync}}"
    case "${NODE_TOKEN_SCOPE,,}" in
        admin) NODE_TOKEN_SCOPE="admin" ;;
        node-admin) NODE_TOKEN_SCOPE="node-admin" ;;
        *) NODE_TOKEN_SCOPE="node-sync" ;;
    esac
    case "${enabled,,}" in y|1|true) ENABLE_NODE_TOKEN=y ;; *) ENABLE_NODE_TOKEN=n; return 0 ;; esac
    case "${AUTO_SETUP_3XUI:-y}" in n|0|false) ENABLE_NODE_TOKEN=n; return 0 ;; esac
    if [ -z "$NODE_TOKEN_NAME" ]; then
        local prefix="${SERVER_PREFIX-Server}"
        case "${prefix,,}" in
            ''|-|none|off|no) NODE_TOKEN_NAME=Master-Node-Cluster ;;
            *)
                local clean_p
                clean_p=$(printf '%s' "$prefix" | tr -cd 'a-zA-Z0-9_-')
                [ -n "$clean_p" ] || clean_p="Server"
                NODE_TOKEN_NAME="${clean_p}-Node"
                ;;
        esac
    fi
}

node_token_runtime_file() {
    if [ -n "${NODE_ENV_FILE:-}" ]; then printf '%s' "$NODE_ENV_FILE";
    elif [ -d /run ]; then printf '/run/3xui_node_token.env';
    else printf '/tmp/3xui_node_token.env'; fi
}

load_node_token_result() {
    local file="$1" line key value
    NODE_TOKEN=""
    [ -f "$file" ] || return 1
    local double_quote='^"(.*)"$' single_quote="^'(.*)'\$"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^(NODE_TOKEN_NAME|NODE_TOKEN|NODE_TOKEN_SCOPE)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        if [[ "$value" =~ $double_quote ]] || [[ "$value" =~ $single_quote ]]; then value="${BASH_REMATCH[1]}"; fi
        printf -v "$key" '%s' "$value"
    done < "$file"
    [ -n "${NODE_TOKEN:-}" ]
}

node_token_operation() {
    "$PYTHON_CMD" - "$@" <<'EOF_NODE_TOKEN_PY'
"""Local node-token lifecycle for the 3X-UI API-token SQLite schema."""
from contextlib import closing
import hashlib
import hmac
import os
from pathlib import Path
import secrets
import sqlite3
import sys
import tempfile
import time


def connect(path):
    return sqlite3.connect(Path(path).resolve().as_uri() + "?mode=rw", uri=True, timeout=10)


def verify(path, name, token, required_scope=None):
    if not token:
        return False
    try:
        with closing(connect(path)) as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute("SELECT * FROM api_tokens WHERE name=?", (name,)).fetchone()
        if row is None or not row["enabled"]:
            return False
        if "expires_at" in row.keys():
            expiry = int(row["expires_at"] or 0)
            if expiry > 100_000_000_000:
                expiry //= 1000
            if expiry and expiry <= int(time.time()):
                return False
        if "scope" in row.keys():
            if row["scope"] not in ("admin", "node-admin", "node-sync"):
                return False
            if required_scope and row["scope"] != required_scope:
                return False
        return hmac.compare_digest(hashlib.sha256(token.encode()).hexdigest(), row["token"])
    except (sqlite3.Error, ValueError, TypeError):
        return False


def create(path, name, scope="node-sync"):
    with closing(connect(path)) as conn, conn:
        columns = {row[1] for row in conn.execute("PRAGMA table_info(api_tokens)")}
        if not {"name", "token", "enabled"} <= columns:
            raise ValueError("Unsupported 3X-UI API-token schema")
        token = secrets.token_hex(32)
        values = {"name": name, "token": hashlib.sha256(token.encode()).hexdigest(), "enabled": 1}
        target_scope = scope if scope else "node-sync"
        scope_map = {
            "node-sync": ("scope", "node-sync"),
            "node-admin": ("scope", "node-admin"),
            "admin": ("scope", "admin"),
        }
        scope_entry = scope_map.get(target_scope, ("scope", target_scope))
        for column, value in (scope_entry, ("created_at", int(time.time())), ("expires_at", 0)):
            if column in columns:
                values[column] = value
        if conn.execute("SELECT 1 FROM api_tokens WHERE name=?", (name,)).fetchone():
            update = {key: value for key, value in values.items() if key != "name"}
            conn.execute("UPDATE api_tokens SET " + ",".join(key + "=?" for key in update) + " WHERE name=?",
                         [*update.values(), name])
        else:
            conn.execute("INSERT INTO api_tokens (" + ",".join(values) + ") VALUES ("
                         + ",".join("?" for _ in values) + ")", list(values.values()))
    return token


def atomic_write(path, text):
    path = Path(path)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def persist(runtime_path, config_path, name, token, scope=None):
    values = {"ENABLE_NODE_TOKEN": "y", "NODE_TOKEN_NAME": name, "NODE_TOKEN": token}
    if scope:
        values["NODE_TOKEN_SCOPE"] = scope
    if any("\n" in value or "\r" in value for value in values.values()):
        raise ValueError("Node-token values must be single-line strings")
    # These files are read as literal KEY=value data, never evaluated as shell code.
    lines = [f'{key}="{value}"' for key, value in values.items()]
    atomic_write(runtime_path, "\n".join(lines) + "\n")
    if config_path and Path(config_path).is_file():
        previous = Path(config_path).read_text(encoding="utf-8").splitlines()
        previous = [line for line in previous if line.partition("=")[0] not in values]
        atomic_write(config_path, "\n".join([*previous, *lines]) + "\n")


def main(args):
    action, *values = args
    if action == "verify":
        return 0 if verify(*values) else 1
    if action == "create":
        print(create(*values))
    elif action == "persist":
        persist(*values)
    else:
        raise ValueError("Unknown node-token operation")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, ValueError, sqlite3.Error) as error:
        print(f"Node API token: {error}", file=sys.stderr)
        raise SystemExit(1)
EOF_NODE_TOKEN_PY
}

ensure_node_token() {
    case "${ENABLE_NODE_TOKEN:-y}" in n|0|false) return 0 ;; esac
    NODE_TOKEN="${NODE_TOKEN:-}"
    local target_scope="${NODE_TOKEN_SCOPE:-node-sync}"
    case "${target_scope,,}" in
        admin) target_scope="admin" ;;
        node-admin) target_scope="node-admin" ;;
        *) target_scope="node-sync" ;;
    esac

    if node_token_operation verify "$DB_PATH" "$NODE_TOKEN_NAME" "$NODE_TOKEN"; then
        ok "Действующий API-ключ ноды '$NODE_TOKEN_NAME' сохранён."
    else
        NODE_TOKEN=""
        local token_out="" attempt
        local -a arguments=()
        if [ -n "${XUI_BIN:-}" ]; then
            for attempt in 1 2 3; do
                case "$attempt" in
                    1) arguments=(-tokenName "$NODE_TOKEN_NAME" -tokenScope "$target_scope") ;;
                    2)
                        # Fallback if 3X-UI version does not support node-sync for -tokenScope
                        if [ "$target_scope" != "admin" ]; then
                            arguments=(-tokenName "$NODE_TOKEN_NAME" -tokenScope admin)
                        else
                            arguments=(-tokenName "$NODE_TOKEN_NAME")
                        fi
                        ;;
                    3) arguments=(-tokenName "$NODE_TOKEN_NAME") ;;
                esac
                token_out=$("$XUI_BIN" setting -getApiToken "${arguments[@]}" 2>&1 || true)
                NODE_TOKEN=$(printf '%s\n' "$token_out" | awk '$1 == "apiToken:" {gsub(/\r/, "", $2); print $2; exit}')
                [ -z "$NODE_TOKEN" ] || break
            done
        fi
        # Also handles CLI versions without named-token flags, without renaming other tokens.
        if ! node_token_operation verify "$DB_PATH" "$NODE_TOKEN_NAME" "$NODE_TOKEN"; then
            NODE_TOKEN=$(node_token_operation create "$DB_PATH" "$NODE_TOKEN_NAME" "$target_scope") || die "Не удалось создать API-ключ ноды 3X-UI."
        fi
        [ -n "$NODE_TOKEN" ] || die "3X-UI не вернул API-ключ ноды."
        local scope_title="Синхронизация узла"
        [ "$target_scope" = "admin" ] && scope_title="Администратор"
        ok "API-ключ ноды '$NODE_TOKEN_NAME' создан (область доступа: $scope_title)."
    fi
    local runtime_file
    runtime_file=$(node_token_runtime_file)
    node_token_operation persist "$runtime_file" "${CONFIG_FILE:-}" "$NODE_TOKEN_NAME" "$NODE_TOKEN" "$target_scope" || die "Не удалось сохранить API-ключ ноды."
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

run_backup_engine() {
    local py_cmd
    py_cmd=$(get_sqlite_backup_python || return 1)
    local script_loc=""
    for cand in \
        "$(dirname "${BASH_SOURCE[0]:-$0}")/backup_engine.py" \
        "$(dirname "${BASH_SOURCE[0]:-$0}")/../common/backup_engine.py" \
        "$(dirname "${BASH_SOURCE[0]:-$0}")/src/common/backup_engine.py" \
        "${SCRIPT_DIR:-.}/src/common/backup_engine.py" \
        "${SCRIPT_DIR:-.}/backup_engine.py"; do
        if [ -f "$cand" ]; then
            script_loc="$cand"
            break
        fi
    done
    if [ -n "$script_loc" ]; then
        "$py_cmd" "$script_loc" "$@"
        return $?
    fi
    "$py_cmd" - "$@" << 'EOF_BACKUP_ENGINE'
"""
src/common/backup_engine.py - Unified Backup & Verification Engine.

Structured Python engine for SQLite WAL-safe live backups, integrity verification,
SHA-256 backup manifest generation/verification, and secure tarfile archive handling.
"""

import hashlib
import json
import os
import sqlite3
import sys
import tarfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Union


def _sha256_file(file_path: Union[str, Path]) -> Optional[str]:
    """Calculate SHA-256 digest of a file in memory-efficient 64KB chunks."""
    h = hashlib.sha256()
    try:
        with open(str(file_path), "rb") as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None


def verify_db(db_path: Union[str, Path]) -> bool:
    """Verify SQLite database integrity using PRAGMA integrity_check."""
    p = str(db_path)
    if not os.path.isfile(p) or os.path.getsize(p) == 0:
        return False
    conn = None
    try:
        abs_p = os.path.abspath(p)
        try:
            conn = sqlite3.connect(f"file:{abs_p}?mode=ro", uri=True, timeout=10.0)
        except Exception:
            conn = sqlite3.connect(p, timeout=10.0)
        res = conn.execute("PRAGMA integrity_check;").fetchall()
        return bool(res and res[0][0] == "ok")
    except Exception:
        return False
    finally:
        if conn:
            try:
                conn.close()
            except Exception:
                pass


def backup_db(src_path: Union[str, Path], dst_path: Union[str, Path]) -> bool:
    """Perform atomic, WAL-safe online backup of an SQLite database."""
    src_p = str(src_path)
    dst_p = str(dst_path)

    if not os.path.isfile(src_p):
        return False

    # Ensure parent directory for destination exists
    dst_dir = os.path.dirname(os.path.abspath(dst_p))
    if dst_dir:
        os.makedirs(dst_dir, exist_ok=True)

    src_conn = None
    dst_conn = None
    try:
        try:
            src_conn = sqlite3.connect(f"file:{src_p}?mode=ro", uri=True, timeout=10.0)
        except Exception:
            src_conn = sqlite3.connect(src_p, timeout=10.0)

        dst_conn = sqlite3.connect(dst_p, timeout=10.0)
        with dst_conn:
            src_conn.backup(dst_conn)
        dst_conn.close()
        dst_conn = None
        src_conn.close()
        src_conn = None

        return verify_db(dst_p)
    except Exception:
        try:
            if os.path.exists(dst_p):
                os.remove(dst_p)
        except OSError:
            pass
        return False
    finally:
        if dst_conn:
            try:
                dst_conn.close()
            except Exception:
                pass
        if src_conn:
            try:
                src_conn.close()
            except Exception:
                pass


def create_manifest(staging_dir: Union[str, Path], output_path: Optional[Union[str, Path]] = None) -> bool:
    """Generate manifest.json with SHA-256 hashes of all files in staging directory."""
    staging = str(staging_dir)
    manifest_path = str(output_path) if output_path else os.path.join(staging, "manifest.json")
    files_map: Dict[str, str] = {}

    for root, _, files in os.walk(staging):
        for f in sorted(files):
            if f == "manifest.json":
                continue
            full_p = os.path.join(root, f)
            rel_p = os.path.relpath(full_p, staging).replace("\\", "/")
            h = _sha256_file(full_p)
            if h is not None:
                files_map[rel_p] = h

    created_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    data = {
        "format_version": "2.0",
        "project_version": os.environ.get("SCRIPT_VERSION", "v9.7.0"),
        "created_at": created_iso,
        "db_path": os.environ.get("DB_PATH", "/etc/x-ui/x-ui.db"),
        "files": files_map,
    }

    try:
        with open(manifest_path, "w", encoding="utf-8") as out:
            json.dump(data, out, indent=2)
        return True
    except Exception:
        return False


def verify_manifest(staging_dir: Union[str, Path], manifest_path: Optional[Union[str, Path]] = None) -> bool:
    """Verify integrity of backed up files against manifest.json with path traversal protection."""
    staging = str(staging_dir)
    man_p = str(manifest_path) if manifest_path else os.path.join(staging, "manifest.json")

    if not os.path.isfile(man_p):
        print(f"[ERROR] Manifest file not found: {man_p}", file=sys.stderr)
        return False

    try:
        with open(man_p, "r", encoding="utf-8") as fp:
            manifest = json.load(fp)
    except Exception as e:
        print(f"[ERROR] Failed to parse manifest {man_p}: {e}", file=sys.stderr)
        return False

    staging_real = os.path.realpath(staging)

    for rel_p, expected_h in manifest.get("files", {}).items():
        # Security: reject entries attempting path traversal or absolute references
        norm_rel = rel_p.replace("\\", "/")
        if os.path.isabs(norm_rel) or norm_rel.startswith("/") or ".." in norm_rel.split("/"):
            print(f"[ERROR] Path traversal detected in manifest entry: {rel_p}", file=sys.stderr)
            return False

        full_p = os.path.realpath(os.path.join(staging, rel_p))
        if not full_p.startswith(staging_real + os.sep) and full_p != staging_real:
            print(f"[ERROR] Manifest entry escapes staging directory: {rel_p}", file=sys.stderr)
            return False

        if not os.path.isfile(full_p):
            print(f"[ERROR] Missing backed up file: {rel_p}", file=sys.stderr)
            return False

        actual_h = _sha256_file(full_p)
        if actual_h is None or actual_h != expected_h:
            print(f"[ERROR] Checksum mismatch for {rel_p}: expected {expected_h}, got {actual_h}", file=sys.stderr)
            return False

    return True


def create_archive(archive_path: Union[str, Path], staging_dir: Union[str, Path]) -> bool:
    """Create gzip-compressed tar archive from items in staging directory."""
    archive = str(archive_path)
    staging = str(staging_dir)

    try:
        with tarfile.open(archive, "w:gz") as tar:
            for item in sorted(os.listdir(staging)):
                tar.add(os.path.join(staging, item), arcname=item)
        return True
    except Exception as e:
        print(f"[ERROR] Failed to create tar archive {archive}: {e}", file=sys.stderr)
        return False


def extract_archive(archive_path: Union[str, Path], target_dir: Union[str, Path]) -> bool:
    """Safely extract gzip-compressed tar archive with path traversal protection."""
    archive = str(archive_path)
    target = str(target_dir)

    os.makedirs(target, exist_ok=True)
    dest = os.path.realpath(target)

    try:
        with tarfile.open(archive, "r:gz") as tar:
            if hasattr(tarfile, "data_filter"):
                tar.extractall(target, filter="data")
            else:
                for m in tar.getmembers():
                    mp = os.path.realpath(os.path.join(dest, m.name))
                    if not mp.startswith(dest + os.sep) and mp != dest:
                        raise RuntimeError(f"Path Traversal detected: {m.name}")
                    if m.islnk() or m.issym():
                        continue
                    tar.extract(m, dest)
        return True
    except Exception as e:
        print(f"[ERROR] Failed to safely extract archive {archive}: {e}", file=sys.stderr)
        return False


def main(argv: Optional[List[str]] = None) -> int:
    """CLI dispatcher for backup engine operations."""
    if argv is None:
        argv = sys.argv[1:]
    if not argv:
        print("Usage: backup_engine.py <command> [args...]", file=sys.stderr)
        return 1

    cmd = argv[0]
    if cmd == "backup_db":
        if len(argv) < 3:
            print("Usage: backup_engine.py backup_db <src> <dst>", file=sys.stderr)
            return 1
        return 0 if backup_db(argv[1], argv[2]) else 1
    elif cmd == "verify_db":
        if len(argv) < 2:
            print("Usage: backup_engine.py verify_db <db_path>", file=sys.stderr)
            return 1
        return 0 if verify_db(argv[1]) else 1
    elif cmd == "create_manifest":
        if len(argv) < 2:
            print("Usage: backup_engine.py create_manifest <staging_dir> [manifest_path]", file=sys.stderr)
            return 1
        out_p = argv[2] if len(argv) > 2 else None
        return 0 if create_manifest(argv[1], out_p) else 1
    elif cmd == "verify_manifest":
        if len(argv) < 2:
            print("Usage: backup_engine.py verify_manifest <staging_dir> [manifest_path]", file=sys.stderr)
            return 1
        man_p = argv[2] if len(argv) > 2 else None
        return 0 if verify_manifest(argv[1], man_p) else 1
    elif cmd == "create_archive":
        if len(argv) < 3:
            print("Usage: backup_engine.py create_archive <archive_path> <staging_dir>", file=sys.stderr)
            return 1
        return 0 if create_archive(argv[1], argv[2]) else 1
    elif cmd == "extract_archive":
        if len(argv) < 3:
            print("Usage: backup_engine.py extract_archive <archive_path> <target_dir>", file=sys.stderr)
            return 1
        return 0 if extract_archive(argv[1], argv[2]) else 1
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
EOF_BACKUP_ENGINE
}

verify_sqlite_backup() {
    local bkp="$1"
    local py_cmd="${2:-}"
    if [ ! -s "$bkp" ]; then
        return 1
    fi
    if [ -n "$py_cmd" ] || get_sqlite_backup_python >/dev/null 2>&1; then
        run_backup_engine verify_db "$bkp" 2>/dev/null && return 0
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
        if run_backup_engine backup_db "$src" "$dst" 2>/dev/null; then
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
        if command -v load_config_data_safe >/dev/null 2>&1; then
            load_config_data_safe "$cfg" 2>/dev/null || true
        fi
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
    run_backup_engine create_manifest "$staging" 2>/dev/null || true

    # 9. Упаковка архива
    if ! run_backup_engine create_archive "$archive" "$staging"; then
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
    if ! run_backup_engine extract_archive "$archive" "$staging"; then
        rm -rf "$staging"
        die "Ошибка безопасной распаковки архива $archive."
    fi

    # 0. Проверка целостности файлов бэкапа по manifest.json (T21.C01, T21.C02)
    if [ -f "$staging/manifest.json" ]; then
        if ! run_backup_engine verify_manifest "$staging"; then
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

    if ! run_backup_engine extract_archive "$archive" "$target"; then
        die "Ошибка извлечения архива $archive."
    fi
    ok "Архив $archive успешно и безопасно извлечён в $target"
    return 0
}

audit_restore_archive() {
    local archive="${1:-}"
    [[ -n "$archive" ]] || die "Укажите путь к архиву: ./maintain.sh --dry-run restore <архив.tar.gz>"
    [[ -f "$archive" ]] || die "Файл архива не найден: $archive"

    local staging
    staging=$(mktemp -d /tmp/vpn-audit-staging.XXXXXX 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/vpn-audit-staging.XXXXXX") || die "Не удалось создать временный каталог для аудита."

    if ! run_backup_engine extract_archive "$archive" "$staging"; then
        rm -rf "$staging"
        die "Ошибка распаковки архива $archive при аудите."
    fi

    # 1. Проверка манифеста (T21.C01, T21.C02)
    if [ -f "$staging/manifest.json" ]; then
        if ! run_backup_engine verify_manifest "$staging"; then
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

# Execute in a fresh Bash so a caller's `if`/`||` cannot suppress errexit.
# A private snapshot preserves Bash functions and unexported variables in both modes.
execute_install_task() (
    umask 077
    task_dir=$(mktemp -d "${TMPDIR:-/tmp}/server-task.XXXXXX") || exit 1
    trap 'rm -f -- "$task_dir/task.sh"; rmdir -- "$task_dir"' EXIT
    {
        declare -p | grep -vE '^declare -[^ ]*r|^declare [^ ]+ (BASH[^ =]*|FUNCNAME|DIRSTACK|GROUPS|PIPESTATUS|LINENO|RANDOM|SRANDOM|SECONDS|EPOCHSECONDS|EPOCHREALTIME|_)='
        declare -f
        cat << 'EOF_TASK_TRAP'
__task_err_handler() {
    local ec=$?
    local cmd="${BASH_COMMAND:-unknown}"
    local line="${BASH_LINENO[0]:-unknown}"
    local fn="${FUNCNAME[1]:-main}"
    printf '\n[ERROR-TRACE] Сбой команды: %s (строка: %s, функция: %s, код: %s)\n' "$cmd" "$line" "$fn" "$ec" >&2
}
trap '__task_err_handler' ERR
EOF_TASK_TRAP
        printf '%s\n' 'shopt -s inherit_errexit 2>/dev/null || true' 'set -Eeuo pipefail' '"$@"'
    } > "$task_dir/task.sh" || exit 1
    bash --noprofile --norc "$task_dir/task.sh" "$@"
)

# Инициализация единого системного журнала установки
init_server_setup_log() {
    if [ -n "${SERVER_SETUP_LOG:-}" ]; then
        return 0
    fi
    local cand
    for cand in "${TARGET_ROOT:-}/var/log/server-setup.log" \
                "${TMPDIR:-/tmp}/server-setup.log"; do
        [ -n "$cand" ] || continue
        local pdir
        pdir="$(dirname "$cand" 2>/dev/null || echo ".")"
        if [ -d "$pdir" ] && [ -w "$pdir" ]; then
            SERVER_SETUP_LOG="$cand"
            break
        fi
    done
    [ -n "${SERVER_SETUP_LOG:-}" ] || SERVER_SETUP_LOG="${TMPDIR:-/tmp}/server-setup.log"
    if [ ! -f "$SERVER_SETUP_LOG" ]; then
        touch "$SERVER_SETUP_LOG" 2>/dev/null && chmod 600 "$SERVER_SETUP_LOG" 2>/dev/null || true
    fi
}

# Извлечение журналов systemd при сбое служб
get_systemd_diagnostic_logs() {
    command -v journalctl >/dev/null 2>&1 || return 0
    [ -d /run/systemd/system ] || return 0

    local diag=""
    if command -v systemctl >/dev/null 2>&1; then
        local failed_units
        failed_units=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' || true)
        if [ -n "$failed_units" ]; then
            diag="${diag}  [systemd: аварийные службы]: ${failed_units}"$'\n'
            for u in $failed_units; do
                local u_logs
                u_logs=$(journalctl -u "$u" -n 15 --no-pager 2>/dev/null || true)
                if [ -n "$u_logs" ]; then
                    diag="${diag}  --- journalctl -u ${u} (последние 15 строк) ---"$'\n'
                    diag="${diag}$(echo "$u_logs" | sed 's/^/    /')"$'\n'
                fi
            done
        fi
    fi

    if [ -z "$diag" ]; then
        local recent_errs
        recent_errs=$(journalctl --since "1 minute ago" -p err..emerg --no-pager -n 15 2>/dev/null || true)
        if [ -n "$recent_errs" ]; then
            diag="${diag}  --- Системные ошибки journalctl (за последнюю минуту) ---"$'\n'
            diag="${diag}$(echo "$recent_errs" | sed 's/^/    /')"$'\n'
        fi
    fi

    if [ -n "$diag" ]; then
        echo -e "\n  ${YELLOW}${BOLD}Диагностика системных служб (journalctl):${NC}"
        echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
        echo "$diag"
        echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
    fi
}

# Interactive Terminal Spinner & Task Runner
# Supports:
#   - Animated spinner in interactive TTY
#   - Plain output in non-interactive / CI / piped runs
#   - Smart Implicit Debug: full output and ERR-traces captured automatically
#   - Explicit DEBUG_MODE=1 passthrough (full stdout/stderr in real-time)
#   - Required tasks support Retry / Abort; failures cannot be marked as success

run_with_spinner() {
    local task_name="$1"
    shift
    init_server_setup_log

    local log_file="${SPINNER_LOG_FILE:-}"
    local temporary_log=0
    if [ -z "$log_file" ]; then
        log_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/server-task-log.XXXXXX") || return 1
        temporary_log=1
    fi

    while true; do
        local exit_code=0
        local task_start_ts
        task_start_ts="$(date -u +"%Y-%m-%d %H:%M:%SZ" 2>/dev/null || date)"
        printf "\n[%s] === START TASK: %s ===\n" "$task_start_ts" "$task_name" >> "$SERVER_SETUP_LOG" 2>/dev/null || true

        # ── DEBUG MODE: трансляция в реальном времени с одновременной записью в лог ──
        if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
            echo -e "\n  ${CYAN}[DEBUG]${NC} ${WHITE}▶ $task_name${NC}"
            echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            (umask 077; : > "$log_file") || true
            chmod 600 "$log_file" 2>/dev/null || true

            local prev_e="0"
            case "$-" in *e*) prev_e="1" ;; esac
            set +e
            execute_install_task "$@" 2>&1 | tee -a "$log_file"
            exit_code=${PIPESTATUS[0]}
            if [ "$prev_e" = "1" ]; then set -e; fi

            if [ -s "$log_file" ] && [ -f "$SERVER_SETUP_LOG" ]; then
                cat "$log_file" >> "$SERVER_SETUP_LOG" 2>/dev/null || true
            fi
            printf "[%s] === END TASK: %s (exit: %s) ===\n" "$(date -u +"%Y-%m-%d %H:%M:%SZ" 2>/dev/null || date)" "$task_name" "$exit_code" >> "$SERVER_SETUP_LOG" 2>/dev/null || true

            if [ $exit_code -eq 0 ]; then
                echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
                echo -e "  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}$task_name${NC} ${GREEN}[ГОТОВО]${NC}\n"
                [ "$temporary_log" -eq 0 ] || rm -f -- "$log_file"
                return 0
            else
                echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
                get_systemd_diagnostic_logs
                echo -e "  ${DIM}Полный журнал выполнения: ${WHITE}${SERVER_SETUP_LOG}${NC}\n"
            fi
        else
            # ── Нормальный режим («Умный неявный Debug»): спиннер + фоновая запись ──
            local spin_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
            local delay=0.08

            (umask 077; : > "$log_file") || return 1
            chmod 600 "$log_file" || return 1

            execute_install_task "$@" >> "$log_file" 2>&1 &
            local pid=$!

            if [ ! -t 1 ]; then
                echo -e "  ${CYAN}*${NC}  ${WHITE}${task_name}...${NC}"
                if wait "$pid"; then exit_code=0; else exit_code=$?; fi
            else
                tput civis 2>/dev/null || echo -ne "\033[?25l"
                local i=0
                while kill -0 "$pid" 2>/dev/null; do
                    i=$(( (i + 1) % 10 ))
                    printf "\r  ${CYAN}${spin_chars[$i]}${NC}  ${WHITE}%-54s${NC}" "$task_name..."
                    sleep "$delay"
                done
                if wait "$pid"; then exit_code=0; else exit_code=$?; fi
                tput cnorm 2>/dev/null || echo -ne "\033[?25h"
            fi

            if [ -s "$log_file" ] && [ -f "$SERVER_SETUP_LOG" ]; then
                cat "$log_file" >> "$SERVER_SETUP_LOG" 2>/dev/null || true
            fi
            printf "[%s] === END TASK: %s (exit: %s) ===\n" "$(date -u +"%Y-%m-%d %H:%M:%SZ" 2>/dev/null || date)" "$task_name" "$exit_code" >> "$SERVER_SETUP_LOG" 2>/dev/null || true

            if [ $exit_code -eq 0 ]; then
                if [ ! -t 1 ]; then
                    printf "  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}%-54s${NC} ${GREEN}[ГОТОВО]${NC}\n" "$task_name"
                else
                    printf "\r  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}%-54s${NC} ${GREEN}[ГОТОВО]${NC}\n" "$task_name"
                fi
                [ "$temporary_log" -eq 0 ] || rm -f -- "$log_file"
                return 0
            fi

            if [ ! -t 1 ]; then
                printf "  ${RED}${CROSS:-✖}${NC}  ${WHITE}%-54s${NC} ${RED}[ОШИБКА]${NC}\n" "$task_name"
            else
                printf "\r  ${RED}${CROSS:-✖}${NC}  ${WHITE}%-54s${NC} ${RED}[ОШИБКА]${NC}\n" "$task_name"
            fi
            echo -e "\n  ${RED}${BOLD}Полный лог ошибки:${NC}"
            echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            [ -f "$log_file" ] && cat "$log_file" | sed 's/^/    /' || true
            echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            get_systemd_diagnostic_logs
            echo -e "  ${DIM}Полный журнал выполнения сохранен в: ${WHITE}${SERVER_SETUP_LOG}${NC}\n"
        fi

        # ── Обязательный этап: повторить или прервать ──
        if [ "${NON_INTERACTIVE:-0}" -eq 0 ] && [ -t 1 ]; then
            echo -e "  ${YELLOW}${BOLD}Действия при сбое:${NC}"
            echo -e "    ${CYAN}${BOLD}[1] Повторить попытку (Retry)${NC} — после исправления причин (напр. DNS)"
            echo -e "    ${RED}[2] Прервать установку (Abort)${NC}"
            local retry_ans=""
            read -rp "  Ваш выбор [1/2] (по умолчанию: 1): " retry_ans </dev/tty || read -r retry_ans || retry_ans="1"
            retry_ans=$(echo "${retry_ans:-1}" | tr -d '[:space:]')
            case "$retry_ans" in
                2|3)
                    if command -v offer_debug_log_export >/dev/null 2>&1; then
                        offer_debug_log_export || true
                    fi
                    die "Шаг завершился с ошибкой (exit $exit_code): $task_name"
                    ;;
                *)
                    echo -e "  ${CYAN}${ARROW:-➜} Повторная попытка: $task_name...${NC}\n"
                    continue
                    ;;
            esac
        else
            return $exit_code
        fi
    done
}

configure_3xui_panel() {
    show_configure_panel_help() {
        cat << 'EOF_HELP'
Использование: ./configure-panel.sh [ОПЦИИ]

Скрипт автоматического конфигурирования и самовосстановления базы 3X-UI (инбаунды, пути, подписки).
Безопасен для повторного запуска: сохраняет существующих клиентов, ключи и кастомные подписки.

Опции:
  -c, --config <FILE>     Путь к файлу параметров (.env) (по умолчанию: ./server-setup.env)
  --db <PATH>             Путь к файлу базы данных SQLite 3X-UI (по умолчанию: /etc/x-ui/x-ui.db)
  --domain <DOMAIN>       Основной домен сервера (например, example.com)
  --sub-domain <DOMAIN>   Домен для раздачи подписок (например, sub.example.com)
  --panel-domain <DOMAIN> Домен веб-панели управления (например, panel.example.com)
  --vless-domain <DOMAIN> Домен для протокола VLESS xHTTP (например, vless.example.com)
  --panel-port <PORT>     Внутренний порт веб-панели (по умолчанию: 2053 для Docker, 10443 для хоста)
  --sub-port <PORT>       Внутренний порт сервера подписок (по умолчанию: 2096 для Docker, 55443 для хоста)
  --hy2-domain <DOMAIN>   Домен для протокола Hysteria 2 (например, hy2.example.com)
  --no-hy2                Отключить Hysteria 2 (не требует SSL-сертификата)
  --dry-run               Только аудит и проверка (без внесения изменений)
  --force-sub             Принудительно перезаписать кастомные параметры подписки из .env
  --force-remarks         Принудительно сбросить названия инбаундов к стандартным из .env
  --regen-keys            Принудительно перегенерировать серверные ключи шифрования (REALITY, SS-2022, MTProxy)
  --warp                  Включить исходящий туннель Cloudflare WARP (обход капч и AI)
  --no-warp               Отключить исходящий туннель Cloudflare WARP
  --warp-key <KEY>        Указать лицензионный ключ WARP+
  --node-token            Создать API-токен для подключения сервера как узла (3X-UI Node)
  --no-node-token         Не создавать API-токен для подключения сервера как узла
  --node-token-name <NAME> Название API-токена ноды (по умолчанию: <SERVER_PREFIX>-Node)
  --node-token-scope <SCOPE> Тип API-токена ноды: node-sync (по умолчанию) или admin
  -y, --yes               Неинтерактивное выполнение (без подтверждений)
  -h, --help              Показать эту справку и выйти

Примеры использования:
  # 1. Обычная настройка / обновление:
  ./configure-panel.sh --config ./server-setup.env -y

  # 2. Безопасный аудит (посмотреть, что изменится, без записи):
  ./configure-panel.sh --dry-run
EOF_HELP
    }

    local CONFIG_FILE=""
    local DB_PATH="/etc/x-ui/x-ui.db"
    local DRY_RUN=0
    local FORCE_SUB=0
    local FORCE_REMARKS=0
    local REGEN_KEYS=0
    local NON_INTERACTIVE=0
    local CLI_ENABLE_WARP=""
    local CLI_WARP_KEY=""
    local CLI_ENABLE_NODE_TOKEN=""
    local CLI_NODE_TOKEN_NAME=""
    local CLI_NODE_TOKEN_SCOPE=""
    local CLI_ENABLE_HY2=""
    local CLI_HY2_DOMAIN=""
    local CLI_VLESS_DOMAIN=""
    local CLI_PANEL_PORT=""
    local CLI_SUB_PORT=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
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
            --domain)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: домен."
                PRIMARY_DOMAIN="$2"
                shift 2
                ;;
            --sub-domain)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: домен подписок."
                SUB_DOMAIN="$2"
                shift 2
                ;;
            --panel-domain)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: домен панели."
                PANEL_DOMAIN="$2"
                shift 2
                ;;
            --vless-domain)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: домен VLESS xHTTP."
                CLI_VLESS_DOMAIN="$2"
                shift 2
                ;;
            --panel-port)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт панели."
                CLI_PANEL_PORT="$2"
                shift 2
                ;;
            --sub-port)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт подписок."
                CLI_SUB_PORT="$2"
                shift 2
                ;;
            --hy2-domain)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: домен Hysteria 2."
                CLI_HY2_DOMAIN="$2"
                shift 2
                ;;
            --hy2)
                CLI_ENABLE_HY2="y"
                shift
                ;;
            --no-hy2)
                CLI_ENABLE_HY2="n"
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --force-sub)
                FORCE_SUB=1
                shift
                ;;
            --force-remarks)
                FORCE_REMARKS=1
                shift
                ;;
            --regen-keys|--rotate-keys)
                REGEN_KEYS=1
                shift
                ;;
            --warp)
                CLI_ENABLE_WARP="y"
                shift
                ;;
            --no-warp)
                CLI_ENABLE_WARP="n"
                shift
                ;;
            --warp-key)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: лицензионный ключ WARP+."
                CLI_WARP_KEY="$2"
                shift 2
                ;;
            --node-token)
                CLI_ENABLE_NODE_TOKEN="y"
                shift
                ;;
            --no-node-token)
                CLI_ENABLE_NODE_TOKEN="n"
                shift
                ;;
            --node-token-name)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: имя токена ноды."
                CLI_NODE_TOKEN_NAME="$2"
                shift 2
                ;;
            --node-token-scope)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: тип (scope) токена ноды."
                CLI_NODE_TOKEN_SCOPE="$2"
                shift 2
                ;;
            -y|--yes)
                NON_INTERACTIVE=1
                shift
                ;;
            -h|--help)
                show_configure_panel_help
                return 0
                ;;
            *)
                warn "Неизвестный параметр: $1"
                show_configure_panel_help
                return 1
                ;;
        esac
    done

    # Захват блокировки для изменяющих операций (T07)
    if [ "$DRY_RUN" -eq 0 ]; then
        acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "configure-panel" || exit $?
    fi

    # Поиск конфигурационного файла (.env)
    if [ -n "$CONFIG_FILE" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            die "Указанный файл конфигурации не найден: $CONFIG_FILE"
        fi
    else
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo ".")"
        if CONFIG_FILE="$(find_config_file "$script_dir")"; then
            log "Обнаружен файл параметров: $CONFIG_FILE"
        else
            CONFIG_FILE=""
        fi
    fi

    if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
        log "Загрузка параметров из $CONFIG_FILE..."
        load_config_data_safe "$CONFIG_FILE" || die "Ошибка загрузки параметров из $CONFIG_FILE"
    fi

    # CLI-аргументы имеют наивысший приоритет над файлом конфигурации
    [ -n "$CLI_ENABLE_WARP" ] && ENABLE_WARP="$CLI_ENABLE_WARP"
    [ -n "$CLI_WARP_KEY" ] && WARP_LICENSE_KEY="$CLI_WARP_KEY"
    [ -n "$CLI_ENABLE_NODE_TOKEN" ] && ENABLE_NODE_TOKEN="$CLI_ENABLE_NODE_TOKEN"
    [ -n "$CLI_NODE_TOKEN_NAME" ] && NODE_TOKEN_NAME="$CLI_NODE_TOKEN_NAME"
    [ -n "$CLI_NODE_TOKEN_SCOPE" ] && NODE_TOKEN_SCOPE="$CLI_NODE_TOKEN_SCOPE"
    NODE_TOKEN_SCOPE="${NODE_TOKEN_SCOPE:-node-sync}"
    [ -n "$CLI_ENABLE_HY2" ] && ENABLE_HY2="$CLI_ENABLE_HY2"
    [ -n "$CLI_HY2_DOMAIN" ] && HY2_DOMAIN="$CLI_HY2_DOMAIN"
    [ -n "$CLI_VLESS_DOMAIN" ] && VLESS_DOMAIN="$CLI_VLESS_DOMAIN"
    [ -n "$CLI_PANEL_PORT" ] && PANEL_PORT="$CLI_PANEL_PORT"
    [ -n "$CLI_SUB_PORT" ] && SUB_PORT="$CLI_SUB_PORT"

    # Дефолтные значения переменных, если не определены в .env
    PRIMARY_DOMAIN="${PRIMARY_DOMAIN:-yourdomain.online}"
    PANEL_PORT="${PANEL_PORT:-}"
    PANEL_PATH="${PANEL_PATH:-}"
    SUB_PORT="${SUB_PORT:-}"
    SUB_PATH="${SUB_PATH:-}"
    SUB_CLASH_PATH="${SUB_CLASH_PATH:-${SUB_PATH%/}/clash}"
    if [ -n "${SERVER_PREFIX:-}" ] && [ "${SERVER_PREFIX,,}" = "auto" ]; then
        SERVER_PREFIX="$(detect_server_location_prefix 2>/dev/null || echo "$PRIMARY_DOMAIN")"
    fi
    SERVER_PREFIX="${SERVER_PREFIX:-$PRIMARY_DOMAIN}"
    ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
    NODE_TOKEN_NAME="${NODE_TOKEN_NAME:-${SERVER_PREFIX}-Node}"
    DIAG_TOKEN="${DIAG_TOKEN:-}"

    STEAL_PORT="${STEAL_PORT:-45443}"
    STEAL_SNI="${STEAL_SNI:-gateway.icloud.com}"
    STEAL_COMPAT_PORT="${STEAL_COMPAT_PORT:-47443}"
    STEAL_COMPAT_DOMAIN="${STEAL_COMPAT_DOMAIN:-static.${PRIMARY_DOMAIN:-}}"
    XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-${XHTTP_PORT:-50443}}"
    XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH:-${XHTTP_PATH:-xhttp}}"
    XHTTP_PORT="$XHTTP_STREAM_PORT"
    XHTTP_PATH="$XHTTP_STREAM_PATH"
    XHTTP_SNI="${XHTTP_SNI:-gateway.icloud.com}"
    CLASSIC_PORT="${CLASSIC_PORT:-46443}"
    CLASSIC_SNI="${CLASSIC_SNI:-dl.google.com}"
    REALITY_FINGERPRINT="${REALITY_FINGERPRINT:-${FINGERPRINT:-firefox}}"
    HY2_PORT="${HY2_PORT:-443}"
    HY2_DOMAIN="${HY2_DOMAIN:-$PRIMARY_DOMAIN}"
    AWG_V3_PORT="${AWG_V3_PORT:-8443}"
    AWG_V2_PORT="${AWG_V2_PORT:-8444}"
    AWG_PRIMARY_DNS="${AWG_PRIMARY_DNS:-9.9.9.9}"
    AWG_SECONDARY_DNS="${AWG_SECONDARY_DNS:-76.76.2.0}"
    AWG_SUBNET_IP="${AWG_SUBNET_IP:-10.8.0.0}"
    AWG_SUBNET_CIDR="${AWG_SUBNET_CIDR:-22}"
    AWG_HEADER_PROTECTION_KEY="${AWG_HEADER_PROTECTION_KEY:-}"
    AWG_RANDOM_TRAILERS="${AWG_RANDOM_TRAILERS:-false}"
    AWG_I1="${AWG_I1:-}"
    SS2022_PORT="${SS2022_PORT:-8388}"
    SHADOWTLS_PORT="${SHADOWTLS_PORT:-8543}"
    SHADOWTLS_SNI="${SHADOWTLS_SNI:-gateway.icloud.com}"
    SHADOWTLS_PASSWORD="${SHADOWTLS_PASSWORD:-}"
    WSTUNNEL_PORT="${WSTUNNEL_PORT:-8080}"
    WSTUNNEL_PREFIX="${WSTUNNEL_PREFIX:-}"
    ZAPRET_QNUM="${ZAPRET_QNUM:-200}"
    ZAPRET_DESYNC="${ZAPRET_DESYNC:-split2}"
    ZAPRET_FOOLING="${ZAPRET_FOOLING:-md5sig,badseq}"
    NAIVE_PORT="${NAIVE_PORT:-8446}"
    NAIVE_DOMAIN="${NAIVE_DOMAIN:-$PRIMARY_DOMAIN}"
    NAIVE_USER="${NAIVE_USER:-user}"
    NAIVE_PASS="${NAIVE_PASS:-}"
    DNSTT_PORT="${DNSTT_PORT:-53053}"
    DNSTT_DOMAIN="${DNSTT_DOMAIN:-}"
    DNSTT_PUBKEY="${DNSTT_PUBKEY:-}"
    TUIC_PORT="${TUIC_PORT:-8448}"
    MTPROTO_PORT="${MTPROTO_PORT:-8444}"
    MTPROTO_FAKETLS_DOMAIN="${MTPROTO_FAKETLS_DOMAIN:-gateway.icloud.com}"
    MTPROTO_ADTAG="${MTPROTO_ADTAG:-}"
    ENABLE_MASQUE="${ENABLE_MASQUE:-n}"
    MASQUE_PORT="${MASQUE_PORT:-8449}"
    MASQUE_USER="${MASQUE_USER:-client}"
    MASQUE_PASSWORD="${MASQUE_PASSWORD:-}"
    REALITY_FALLBACK_PORT="${REALITY_FALLBACK_PORT:-9443}"
    STEAL_DOMAINS="${STEAL_DOMAINS[*]:-${STEAL_DOMAINS:-cdn.$PRIMARY_DOMAIN}}"
    SUB_TITLE="${SUB_TITLE:-${SERVER_PREFIX:-Server}}"
    CLIENT_EMAIL="${CLIENT_EMAIL:-${CLIENT_NAME:-}}"
    CLIENT_NAME="${CLIENT_NAME:-${CLIENT_EMAIL:-}}"

    ENABLE_STEAL="${ENABLE_STEAL:-y}"
    ENABLE_STEAL_COMPAT="${ENABLE_STEAL_COMPAT:-n}"
    ENABLE_XHTTP="${ENABLE_XHTTP:-y}"
    ENABLE_CLASSIC="${ENABLE_CLASSIC:-y}"
    ENABLE_HY2="${ENABLE_HY2:-y}"
    ENABLE_AWG_V3="${ENABLE_AWG_V3:-y}"
    ENABLE_AWG_V2="${ENABLE_AWG_V2:-n}"
    ENABLE_SS2022="${ENABLE_SS2022:-n}"
    ENABLE_SHADOWTLS="${ENABLE_SHADOWTLS:-n}"
    ENABLE_WSTUNNEL="${ENABLE_WSTUNNEL:-n}"
    ENABLE_ZAPRET="${ENABLE_ZAPRET:-n}"
    ENABLE_NAIVE="${ENABLE_NAIVE:-n}"
    ENABLE_DNSTT="${ENABLE_DNSTT:-n}"
    ENABLE_TUIC="${ENABLE_TUIC:-n}"
    ENABLE_MTPROTO="${ENABLE_MTPROTO:-n}"

    ENABLE_WARP="${ENABLE_WARP:-n}"
    WARP_LICENSE_KEY="${WARP_LICENSE_KEY:-}"
    TIME_LOCATION="${TIME_LOCATION:-Europe/Moscow}"
    SUB_UPDATES="${SUB_UPDATES:-1}"
    SUB_ENCRYPT="${SUB_ENCRYPT:-true}"
    BLOCK_SMTP="${BLOCK_SMTP:-true}"
    BLOCK_LAN="${BLOCK_LAN:-true}"
    ENABLE_AGH="${ENABLE_AGH:-n}"
    PORT_AGH_DNS="${PORT_AGH_DNS:-10053}"
    AGH_XRAY_DNS="${AGH_XRAY_DNS:-127.0.0.1:10053}"

    HAS_NGINX=0
    if command -v nginx >/dev/null 2>&1 && [ -d /etc/nginx ]; then
        HAS_NGINX=1
    fi

    if [ -n "${WEB_LISTEN:-}" ]; then
        WEB_LISTEN="$WEB_LISTEN"
    elif [ "$HAS_NGINX" -eq 1 ]; then
        WEB_LISTEN="127.0.0.1"
    else
        WEB_LISTEN=""
    fi

    if [ -n "${SUB_LISTEN:-}" ]; then
        SUB_LISTEN="$SUB_LISTEN"
    elif [ "$HAS_NGINX" -eq 1 ]; then
        SUB_LISTEN="127.0.0.1"
    else
        SUB_LISTEN=""
    fi

    resolve_ssl_cert_paths "$PRIMARY_DOMAIN" "SSL"
    resolve_ssl_cert_paths "${HY2_DOMAIN:-$PRIMARY_DOMAIN}" "HY2"
    resolve_ssl_cert_paths "${TUIC_DOMAIN:-$PRIMARY_DOMAIN}" "TUIC"

    # Определение работоспособной команды Python
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
            apt-get update -q && apt-get install -y python3 python3-bcrypt -q 2>/dev/null || apt-get install -y python3 -q || die "Не удалось установить python3."
            PYTHON_CMD="python3"
        else
            die "Работоспособный Python 3 не найден в системе. Необходим для анализа базы SQLite."
        fi
    elif [ "$DRY_RUN" -eq 0 ]; then
        if command -v apt-get >/dev/null 2>&1 && ! "$PYTHON_CMD" -c "import bcrypt" >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get install -y python3-bcrypt -q 2>/dev/null || true
        fi
    fi

    # Проверка наличия базы данных 3X-UI
    IS_DOCKER_XUI=0
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
        if [ "$found" -eq 0 ] && command -v docker >/dev/null 2>&1; then
            local doc_vol=""
            doc_vol=$(docker volume ls -q 2>/dev/null | grep 'xui_data' | head -n1 || true)
            if [ -n "$doc_vol" ]; then
                local mnt=""
                mnt=$(docker volume inspect "$doc_vol" --format '{{.Mountpoint}}' 2>/dev/null || true)
                if [ -n "$mnt" ] && [ -f "$mnt/x-ui.db" ]; then
                    DB_PATH="$mnt/x-ui.db"
                    found=1
                    IS_DOCKER_XUI=1
                    ok "Обнаружена база данных 3X-UI в Docker Volume ($doc_vol): $DB_PATH"
                fi
            fi
        fi
        if [ "$found" -eq 0 ]; then
            if [ "$DRY_RUN" -eq 1 ]; then
                die "База данных 3X-UI ($DB_PATH) не найдена. Убедитесь, что панель 3X-UI установлена."
            fi
            log "Служба 3X-UI не обнаружена на сервере. Автоматическая установка..."
            install_3xui_task() {
                export DEBIAN_FRONTEND=noninteractive
                curl -Ls --connect-timeout 15 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/install_3xui.sh
                printf "n\n" | bash /tmp/install_3xui.sh
            }
            run_with_spinner "Установка официального ядра 3X-UI (mhsanaei)" install_3xui_task
            for p in "$DB_PATH" "/usr/local/x-ui/bin/x-ui.db" "/etc/x-ui/db/x-ui.db"; do
                if [ -f "$p" ]; then
                    DB_PATH="$p"
                    found=1
                    break
                fi
            done
            if [ "$found" -eq 0 ]; then
                die "Не удалось найти базу данных 3X-UI после установки. Установите вручную: bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)"
            fi
            ok "Панель 3X-UI успешно установлена!"
            WAS_ACTIVE=1
        fi
    fi

    log "Используется база данных 3X-UI: $DB_PATH"

    if [ "$DRY_RUN" -eq 0 ]; then
        BACKUP_TS="$(date +%Y%m%d_%H%M%S)"
        BACKUP_DB="${DB_PATH}.bak.${BACKUP_TS}"
        if ! backup_sqlite_db "$DB_PATH" "$BACKUP_DB"; then
            die "Критическая ошибка: невозможно создать проверенную резервную копию базы данных $DB_PATH. Внесение изменений отменено во избежание повреждения данных."
        fi
    fi

    if [ "${IS_DOCKER_XUI:-0}" -eq 1 ]; then
        PANEL_PORT="${PANEL_PORT:-2053}"
        SUB_PORT="${SUB_PORT:-2096}"
    else
        PANEL_PORT="${PANEL_PORT:-10443}"
        SUB_PORT="${SUB_PORT:-55443}"
    fi

    export DB_PATH
    export DRY_RUN
    export FORCE_SUB
    export PRIMARY_DOMAIN
    export SUB_DOMAIN="${SUB_DOMAIN:-}"
    export PANEL_DOMAIN="${PANEL_DOMAIN:-}"
    export VLESS_DOMAIN="${VLESS_DOMAIN:-}"
    export PANEL_PORT
    export PANEL_PATH
    export SUB_PORT
    export IS_DOCKER_XUI
    export SUB_PATH
    export SUB_CLASH_PATH
    export ENABLE_STEAL
    export ENABLE_STEAL_COMPAT
    export STEAL_PORT
    export STEAL_COMPAT_PORT
    export STEAL_COMPAT_DOMAIN
    export STEAL_SNI
    export ENABLE_XHTTP
    export XHTTP_PORT
    export XHTTP_PATH
    export XHTTP_STREAM_PORT
    export XHTTP_STREAM_PATH
    export XHTTP_SNI
    export ENABLE_CLASSIC
    export CLASSIC_PORT
    export CLASSIC_SNI
    export REALITY_FINGERPRINT
    export ENABLE_HY2
    export HY2_PORT
    export HY2_DOMAIN
    export HY2_CERT_PATH
    export HY2_KEY_PATH
    export ENABLE_AWG_V3
    export AWG_V3_PORT
    export ENABLE_AWG_V2
    export AWG_V2_PORT
    export AWG_PRIMARY_DNS
    export AWG_SECONDARY_DNS
    export AWG_SUBNET_IP
    export AWG_SUBNET_CIDR
    export AWG_HEADER_PROTECTION_KEY
    export AWG_RANDOM_TRAILERS
    export ENABLE_SS2022
    export SS2022_PORT
    export ENABLE_SHADOWTLS
    export SHADOWTLS_PORT
    export SHADOWTLS_SNI
    export SHADOWTLS_PASSWORD
    export ENABLE_NAIVE
    export NAIVE_PORT
    export NAIVE_DOMAIN
    export NAIVE_USER
    export NAIVE_PASS
    export ENABLE_DNSTT
    export DNSTT_PORT
    export DNSTT_DOMAIN
    export DNSTT_PUBKEY
    export ENABLE_TUIC
    export TUIC_PORT
    export TUIC_CERT_PATH
    export TUIC_KEY_PATH
    export ENABLE_MTPROTO
    export MTPROTO_PORT
    export MTPROTO_FAKETLS_DOMAIN
    export MTPROTO_ADTAG
    export SSL_CERT_PATH
    export SSL_KEY_PATH
    export ADMIN_USERNAME
    export ADMIN_PASSWORD
    export SERVER_PREFIX
    export SUB_TITLE
    export REALITY_FALLBACK_PORT
    export STEAL_DOMAINS
    export ENABLE_MASQUE
    export MASQUE_PORT
    export MASQUE_USER
    export MASQUE_PASSWORD
    export ENABLE_ZAPRET
    export ZAPRET_QNUM
    export ZAPRET_DESYNC
    export ZAPRET_FOOLING
    export AWG_I1
    export CLIENT_EMAIL
    export CLIENT_NAME
    export ENABLE_WARP
    export WARP_LICENSE_KEY
    export TIME_LOCATION
    export SUB_UPDATES
    export SUB_ENCRYPT
    export BLOCK_SMTP
    export ENABLE_WSTUNNEL="${ENABLE_WSTUNNEL:-n}"
    export WSTUNNEL_PREFIX="${WSTUNNEL_PREFIX:-}"
    export WSTUNNEL_PORT="${WSTUNNEL_PORT:-8080}"
    export ENABLE_MIERU="${ENABLE_MIERU:-n}"
    export MIERU_PORT="${MIERU_PORT:-8450}"
    export MIERU_PORT_MODE="${MIERU_PORT_MODE:-single}"
    export MIERU_TRANSPORT="${MIERU_TRANSPORT:-BOTH}"
    export MIERU_USER="${MIERU_USER:-}"
    export MIERU_PASS="${MIERU_PASS:-}"
    export BLOCK_LAN
    export WEB_LISTEN
    export SUB_LISTEN
    export ENABLE_AGH
    export PORT_AGH_DNS
    export AGH_XRAY_DNS
    export FORCE_REMARKS
    export INBOUND_TRAFFIC_RESET="${INBOUND_TRAFFIC_RESET:-monthly}"
    export INBOUND_TRAFFIC_RESET_DAY="${INBOUND_TRAFFIC_RESET_DAY:-1}"

    # Приостановка службы x-ui на время реальной транзакции во избежание блокировок SQLite
    WAS_ACTIVE=0
    cleanup_xui() {
        if [ "${WAS_ACTIVE:-0}" -eq 1 ]; then
            if [ "${IS_DOCKER_XUI:-0}" -eq 1 ]; then
                docker start 3x-ui-dokploy >/dev/null 2>&1 || true
            else
                svc_start x-ui 2>/dev/null || systemctl start x-ui 2>/dev/null || true
            fi
        fi
        command -v release_stack_lock >/dev/null 2>&1 && release_stack_lock
    }
    trap cleanup_xui EXIT

    if [ -f /etc/init.d/x-ui ] && ! grep -q 'directory=' /etc/init.d/x-ui 2>/dev/null; then
        sed -i '/command=/a directory="/usr/local/x-ui"' /etc/init.d/x-ui 2>/dev/null || true
    fi

    if [ "$DRY_RUN" -eq 0 ]; then
        if [ "${IS_DOCKER_XUI:-0}" -eq 1 ]; then
            log "Остановка контейнера 3X-UI на время обновления конфигурации базы..."
            docker stop 3x-ui-dokploy >/dev/null 2>&1 || true
            WAS_ACTIVE=1
        elif svc_is_active x-ui 2>/dev/null || (command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet x-ui 2>/dev/null); then
            log "Приостановка службы 3X-UI на время обновления конфигурации базы..."
            svc_stop x-ui 2>/dev/null || systemctl stop x-ui 2>/dev/null || true
            WAS_ACTIVE=1
        fi
    fi

    log "Конфигурирование таблиц settings и inbounds (Smart Reconcile Engine)..."
    export REGEN_SERVER_KEYS="${REGEN_KEYS:-${REGEN_SERVER_KEYS:-0}}"

    "$PYTHON_CMD" - << 'EOF_PYTHON_CONFIG'
import os
import sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

import sqlite3
import json
import uuid
import secrets
import base64
import time
import urllib.request
import urllib.parse
import re
import shlex

if "generate_dnstt_keypair" not in globals():
    try:
        from src.common.crypto_engine import generate_dnstt_keypair
    except ImportError:
        try:
            from common.crypto_engine import generate_dnstt_keypair
        except ImportError:
            try:
                from crypto_engine import generate_dnstt_keypair
            except ImportError:
                try:
                    from pathlib import Path
                    _p = (Path(__file__).resolve().parent.parent / "common").as_posix()
                    if _p not in sys.path:
                        sys.path.insert(0, _p)
                    from crypto_engine import generate_dnstt_keypair
                except Exception:
                    pass

db_path = os.environ["DB_PATH"]
dry_run = os.environ.get("DRY_RUN", "0") == "1"
force_sub = os.environ.get("FORCE_SUB", "0") == "1"
force_remarks = os.environ.get("FORCE_REMARKS", "0") == "1"
regen_server_keys = os.environ.get("REGEN_SERVER_KEYS", "0") == "1"

conn = sqlite3.connect(db_path, timeout=30.0)
cur = conn.cursor()

# Извлечение существующих параметров из таблицы settings
existing_settings = {}
try:
    cur.execute("SELECT key, value FROM settings")
    for k, v in cur.fetchall():
        existing_settings[k] = v
except Exception as e:
    print(f"[!] Предупреждение: ошибка чтения таблицы settings: {e}")

# Глобальная санитизация externalProxy во всех существующих инбаундах базы данных
try:
    cur.execute("SELECT id, remark, stream_settings FROM inbounds")
    for _g_id, _g_rem, _g_st_raw in cur.fetchall():
        if not _g_st_raw:
            continue
        try:
            _g_st = json.loads(_g_st_raw)
        except Exception:
            continue
        _g_ext = _g_st.get("externalProxy")
        if isinstance(_g_ext, list) and len(_g_ext) > 0:
            _g_modified = False
            for _g_ep in _g_ext:
                if isinstance(_g_ep, dict) and "alpn" in _g_ep and isinstance(_g_ep["alpn"], str):
                    _g_ep["alpn"] = [_g_ep["alpn"]] if _g_ep["alpn"] else []
                    _g_modified = True
            if _g_modified and not dry_run:
                cur.execute("UPDATE inbounds SET stream_settings = ? WHERE id = ?", (json.dumps(_g_st, ensure_ascii=False), _g_id))
                print(f"  [ИСПРАВЛЕНО] Инбаунд #{_g_id} ({_g_rem}): тип alpn в externalProxy исправлен со строки на массив")
except Exception as _e_ext_scan:
    pass

domain = os.environ.get("PRIMARY_DOMAIN") or existing_settings.get("subDomain") or "localhost"
is_docker_env = os.environ.get("IS_DOCKER_XUI", "0") == "1"
def_p_port = "2053" if is_docker_env else "10443"
def_s_port = "2096" if is_docker_env else "55443"
panel_port = os.environ.get("PANEL_PORT") or existing_settings.get("webPort") or def_p_port
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

panel_path = resolve_panel_path(os.environ.get("PANEL_PATH"), existing_settings.get("webBasePath"))

sub_port = os.environ.get("SUB_PORT") or existing_settings.get("subPort") or def_s_port
sub_env = (os.environ.get("SUB_PATH") or "").strip("/")
if sub_env and sub_env != "my-post-key":
    sub_path = sub_env
else:
    sub_db = (existing_settings.get("subPath") or "").strip("/")
    if sub_db and sub_db != "my-post-key":
        sub_path = sub_db
    else:
        import secrets
        sub_path = "sub-" + secrets.token_hex(4)
sub_clash_env = (os.environ.get("SUB_CLASH_PATH") or "").strip().strip("/")
if sub_clash_env:
    sub_clash_path = sub_clash_env
else:
    sub_clash_db = (existing_settings.get("subClashPath") or "").strip().strip("/")
    if sub_clash_db and sub_clash_db != f"{sub_path}clash":
        sub_clash_path = sub_clash_db
    else:
        sub_clash_path = f"{sub_path}/clash"

xhttp_port = int(os.environ.get("XHTTP_STREAM_PORT") or os.environ.get("XHTTP_PORT") or "50443")
xhttp_raw_path = (os.environ.get("XHTTP_STREAM_PATH") or os.environ.get("XHTTP_PATH") or "").strip("/")
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

enable_steal_compat = os.environ.get("ENABLE_STEAL_COMPAT", "n").lower() in ("1", "y", "true")
steal_compat_port = int(os.environ.get("STEAL_COMPAT_PORT") or "47443")
steal_compat_dom = os.environ.get("STEAL_COMPAT_DOMAIN") or f"static.{domain}"
steal_compat_dom = steal_compat_dom.split()[0] if steal_compat_dom.strip() else f"static.{domain}"

enable_classic = os.environ.get("ENABLE_CLASSIC", "y").lower() in ("1", "y", "true")
classic_port = int(os.environ.get("CLASSIC_PORT") or "46443")
classic_raw = os.environ.get("CLASSIC_SNI") or "dl.google.com"
_parsed_snis = []
_seen_snis = set()
for _s in classic_raw.replace(",", " ").split():
    _clean_s = _s.strip().strip(".").lower()
    if _clean_s and _clean_s not in _seen_snis:
        _seen_snis.add(_clean_s)
        _parsed_snis.append(_clean_s)
classic_snis = _parsed_snis if _parsed_snis else ["dl.google.com"]
classic_sni = classic_snis[0]

VALID_FINGERPRINTS = {"chrome", "firefox", "safari", "ios", "android", "edge", "360", "qq", "random", "randomized"}
_raw_fp = (os.environ.get("REALITY_FINGERPRINT") or "firefox").strip().lower()
reality_fingerprint = _raw_fp if (_raw_fp in VALID_FINGERPRINTS or _raw_fp) else "firefox"

def resolve_cert_key_paths(target_dom: str, env_cert: str = "", env_key: str = "") -> tuple:
    """
    Unified SSL certificate resolver: returns (cert_path, key_path).
    Prioritizes explicit valid files, then Let's Encrypt (/etc/letsencrypt/live),
    then ACME (/etc/ssl/acme for Cloudflare DNS-01 API),
    then container persistent storage (/etc/x-ui/server.crt or db_dir).
    """
    if env_cert and env_key and os.path.isfile(env_cert) and os.path.isfile(env_key):
        return env_cert, env_key
    le_cert = f"/etc/letsencrypt/live/{target_dom}/fullchain.pem"
    le_key = f"/etc/letsencrypt/live/{target_dom}/privkey.pem"
    if os.path.isfile(le_cert) and os.path.isfile(le_key):
        return le_cert, le_key
    acme_cert = f"/etc/ssl/acme/{target_dom}/fullchain.pem"
    acme_key = f"/etc/ssl/acme/{target_dom}/privkey.pem"
    if os.path.isfile(acme_cert) and os.path.isfile(acme_key):
        return acme_cert, acme_key

    # Проверка наличия сертификата в каталоге базы (персистентный том /etc/x-ui)
    _db_d = os.path.dirname(os.path.abspath(db_path)) if "db_path" in globals() else "/etc/x-ui"
    _h_c = os.path.join(_db_d, "server.crt")
    _h_k = os.path.join(_db_d, "server.key")
    if os.path.isfile(_h_c) and os.path.isfile(_h_k):
        return "/etc/x-ui/server.crt", "/etc/x-ui/server.key"
    if os.path.isfile("/etc/x-ui/server.crt") and os.path.isfile("/etc/x-ui/server.key"):
        return "/etc/x-ui/server.crt", "/etc/x-ui/server.key"

    # Автогенерация самоподписанного сертификата в каталоге x-ui, если openssl доступен
    try:
        import subprocess
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", _h_k, "-out", _h_c, "-days", "3650",
             "-subj", f"/CN={target_dom}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True
        )
        if os.path.isfile(_h_c) and os.path.isfile(_h_k):
            print(f"  [СОЗДАНО] Автоматически сгенерирован самоподписанный SSL для {target_dom}: /etc/x-ui/server.crt")
            return "/etc/x-ui/server.crt", "/etc/x-ui/server.key"
    except Exception:
        pass

    return env_cert or le_cert, env_key or le_key


ssl_cert, ssl_key = resolve_cert_key_paths(domain, os.environ.get("SSL_CERT_PATH", ""), os.environ.get("SSL_KEY_PATH", ""))

enable_hy2 = os.environ.get("ENABLE_HY2", "y").lower() in ("1", "y", "true")
hy2_port = int(os.environ.get("HY2_PORT") or "443")
hy2_domain = (os.environ.get("HY2_DOMAIN") or domain).strip()
hy2_cert, hy2_key = resolve_cert_key_paths(hy2_domain, os.environ.get("HY2_CERT_PATH", ""), os.environ.get("HY2_KEY_PATH", ""))

enable_awg_v3 = os.environ.get("ENABLE_AWG_V3", "y").lower() in ("1", "y", "true")
awg_v3_port = int(os.environ.get("AWG_V3_PORT") or "8443")

enable_awg_v2 = os.environ.get("ENABLE_AWG_V2", "n").lower() in ("1", "y", "true")
awg_v2_port = int(os.environ.get("AWG_V2_PORT") or "8444")
awg_primary_dns = os.environ.get("AWG_PRIMARY_DNS") or "9.9.9.9"
awg_secondary_dns = os.environ.get("AWG_SECONDARY_DNS") or "76.76.2.0"
awg_subnet_ip = os.environ.get("AWG_SUBNET_IP") or "10.8.0.0"
awg_subnet_cidr = int(os.environ.get("AWG_SUBNET_CIDR") or "22")
awg_hpk_env = os.environ.get("AWG_HEADER_PROTECTION_KEY", "").strip()
awg_random_trailers_env = os.environ.get("AWG_RANDOM_TRAILERS", "false").strip().lower() in ("1", "y", "true")

enable_ss2022 = os.environ.get("ENABLE_SS2022", "n").lower() in ("1", "y", "true")
ss2022_port = int(os.environ.get("SS2022_PORT") or "8388")
enable_shadowtls = os.environ.get("ENABLE_SHADOWTLS", "n").lower() in ("1", "y", "true")
shadowtls_port = int(os.environ.get("SHADOWTLS_PORT") or "8543")
shadowtls_sni = (os.environ.get("SHADOWTLS_SNI") or "gateway.icloud.com").strip()
shadowtls_password = os.environ.get("SHADOWTLS_PASSWORD", "").strip()

enable_tuic = os.environ.get("ENABLE_TUIC", "n").lower() in ("1", "y", "true")
tuic_port = int(os.environ.get("TUIC_PORT") or "8448")

enable_mtproto = os.environ.get("ENABLE_MTPROTO", "n").lower() in ("1", "y", "true")
mtproto_port = int(os.environ.get("MTPROTO_PORT") or "8444")
mtproto_faketls_domain = (os.environ.get("MTPROTO_FAKETLS_DOMAIN") or "gateway.icloud.com").strip()
mtproto_adtag = os.environ.get("MTPROTO_ADTAG", "").strip()

# Определение ID администратора и настройка учетных данных
admin_user = os.environ.get("ADMIN_USERNAME", "").strip()
admin_pass = os.environ.get("ADMIN_PASSWORD", "").strip()
server_prefix = os.environ.get("SERVER_PREFIX", "").strip()
if server_prefix.lower() in ("-", "none", "off", "no"):
    server_prefix = ""
elif server_prefix.lower() == "auto":
    _cache_p = "/run/setup_mask_server_prefix" if os.path.isdir("/run") else "/tmp/setup_mask_server_prefix"
    _resolved = ""
    try:
        if os.path.exists(_cache_p):
            with open(_cache_p, "r", encoding="utf-8") as _f:
                _resolved = _f.read().strip()
    except Exception:
        pass
    server_prefix = _resolved if _resolved else "Server"

def make_remark(method):
    if server_prefix:
        return f"{server_prefix} {method}"
    return method

hashed_pass = None
if admin_pass:
    if admin_pass.startswith("$2a$") or admin_pass.startswith("$2b$") or admin_pass.startswith("$2y$"):
        hashed_pass = admin_pass
    else:
        try:
            import bcrypt
            hashed_pass = bcrypt.hashpw(admin_pass.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")
        except Exception:
            pass

cur.execute("SELECT id, username, password FROM users LIMIT 1")
user_row = cur.fetchone()
if user_row:
    admin_id, curr_user, curr_pass = user_row
    new_user = admin_user if admin_user else curr_user
    new_pass = hashed_pass if hashed_pass else curr_pass
    if admin_user or hashed_pass:
        if not dry_run:
            if hashed_pass:
                cur.execute("UPDATE users SET username = ?, password = ? WHERE id = ?", (new_user, new_pass, admin_id))
            else:
                cur.execute("UPDATE users SET username = ? WHERE id = ?", (new_user, admin_id))
        status_msg = "пароль обновлен (bcrypt)" if hashed_pass else "пароль будет синхронизирован через CLI x-ui"
        print(f"  [ИСПРАВЛЕНО] Администратор (ID {admin_id}): логин='{new_user}', {status_msg}.")
    elif admin_pass:
        print(f"  [ИНФО] Администратор (ID {admin_id}): логин='{new_user}', пароль ожидает хэширования через CLI x-ui.")
else:
    admin_id = 1
    new_pass = hashed_pass if hashed_pass else "admin"
    if not dry_run:
        cur.execute("INSERT INTO users (id, username, password) VALUES (1, ?, ?)", (admin_user or "admin", new_pass))
    print(f"  [СОЗДАНО] Администратор: логин='{admin_user or 'admin'}', пароль создан.")

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
inbounds_cols = get_table_columns("inbounds")

if "inbounds" in all_tables:
    if "traffic_reset" not in inbounds_cols and "trafficReset" not in inbounds_cols:
        try:
            cur.execute("ALTER TABLE inbounds ADD COLUMN traffic_reset TEXT DEFAULT 'never'")
            inbounds_cols.add("traffic_reset")
        except Exception:
            pass
    if "traffic_reset_day" not in inbounds_cols and "trafficResetDay" not in inbounds_cols:
        try:
            cur.execute("ALTER TABLE inbounds ADD COLUMN traffic_reset_day INTEGER DEFAULT 1")
            inbounds_cols.add("traffic_reset_day")
        except Exception:
            pass
    if "last_traffic_reset_time" not in inbounds_cols and "lastTrafficResetTime" not in inbounds_cols:
        try:
            cur.execute("ALTER TABLE inbounds ADD COLUMN last_traffic_reset_time INTEGER DEFAULT 0")
            inbounds_cols.add("last_traffic_reset_time")
        except Exception:
            pass

inbound_traffic_reset = os.environ.get("INBOUND_TRAFFIC_RESET", "monthly").strip().lower() or "monthly"
try:
    inbound_traffic_reset_day = int(os.environ.get("INBOUND_TRAFFIC_RESET_DAY", "1").strip() or "1")
except (ValueError, TypeError):
    inbound_traffic_reset_day = 1

# Глобальная настройка ежемесячного сброса трафика для всех существующих инбаундов
try:
    _tr_col = "traffic_reset" if "traffic_reset" in inbounds_cols else ("trafficReset" if "trafficReset" in inbounds_cols else None)
    _trd_col = "traffic_reset_day" if "traffic_reset_day" in inbounds_cols else ("trafficResetDay" if "trafficResetDay" in inbounds_cols else None)
    if _tr_col and not dry_run:
        if _trd_col:
            cur.execute(f"UPDATE inbounds SET {_tr_col} = ?, {_trd_col} = ? WHERE {_tr_col} IS NULL OR {_tr_col} = '' OR {_tr_col} = 'never'", (inbound_traffic_reset, inbound_traffic_reset_day))
        else:
            cur.execute(f"UPDATE inbounds SET {_tr_col} = ? WHERE {_tr_col} IS NULL OR {_tr_col} = '' OR {_tr_col} = 'never'", (inbound_traffic_reset,))
        if cur.rowcount > 0:
            print(f"  [ОБНОВЛЕНО] Сброс трафика ({inbound_traffic_reset}, день {inbound_traffic_reset_day} в 00:00) активирован для {cur.rowcount} инбаунд(ов).")
except Exception as _e_tr:
    pass

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
            
        # 4. Расписание сброса трафика клиента (ежемесячно 1-го числа в 00:00)
        c_tr = globals().get("inbound_traffic_reset", "monthly")
        c_tr_day = globals().get("inbound_traffic_reset_day", 1)
        if "trafficReset" not in client or client.get("trafficReset") in ("", "never", None):
            client["trafficReset"] = c_tr
        if "trafficResetDay" not in client or not client.get("trafficResetDay"):
            client["trafficResetDay"] = c_tr_day
        if "resetDay" not in client or not client.get("resetDay"):
            client["resetDay"] = c_tr_day
            
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
                for r_col in ["reset_day", "resetDay"]:
                    if r_col in client_traffics_cols:
                        ct_data[r_col] = c_tr_day
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
                for r_col in ["reset_day", "resetDay"]:
                    if r_col in client_traffics_cols:
                        ct_updates[r_col] = c_tr_day
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
                for tr_c in ["traffic_reset", "trafficReset"]:
                    if tr_c in clients_cols: c_data[tr_c] = c_tr
                for trd_c in ["traffic_reset_day", "trafficResetDay", "reset_day", "resetDay"]:
                    if trd_c in clients_cols: c_data[trd_c] = c_tr_day
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
                    if "wg_keep_alive_range" in clients_cols:
                        c_data["wg_keep_alive_range"] = str(client.get("keepAlive") or "15-25")
                    elif "wg_keep_alive" in clients_cols and client.get("keepAlive"):
                        try:
                            c_data["wg_keep_alive"] = int(str(client.get("keepAlive")).split("-")[0])
                        except (ValueError, TypeError):
                            pass
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
                for tr_c in ["traffic_reset", "trafficReset"]:
                    if tr_c in clients_cols: c_updates[tr_c] = c_tr
                for trd_c in ["traffic_reset_day", "trafficResetDay", "reset_day", "resetDay"]:
                    if trd_c in clients_cols: c_updates[trd_c] = c_tr_day
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
                    if "wg_keep_alive_range" in clients_cols:
                        c_updates["wg_keep_alive_range"] = str(client.get("keepAlive") or "15-25")
                    elif "wg_keep_alive" in clients_cols and client.get("keepAlive"):
                        try:
                            c_updates["wg_keep_alive"] = int(str(client.get("keepAlive")).split("-")[0])
                        except (ValueError, TypeError):
                            pass
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

# Curve25519 helper (RFC 7748) via common crypto engine
try:
    from src.common.crypto_engine import (
        P, A24, clamp, x25519, curve25519_pubkey, curve25519_reality_pubkey,
        generate_reality_keypair, generate_wg_keypair, generate_dnstt_keypair,
        dnstt_pubkey_from_privkey, validate_dnstt_pubkey
    )
except ImportError:
    try:
        from common.crypto_engine import (
            P, A24, clamp, x25519, curve25519_pubkey, curve25519_reality_pubkey,
            generate_reality_keypair, generate_wg_keypair, generate_dnstt_keypair,
            dnstt_pubkey_from_privkey, validate_dnstt_pubkey
        )
    except ImportError:
        try:
            from crypto_engine import (
                P, A24, clamp, x25519, curve25519_pubkey, curve25519_reality_pubkey,
                generate_reality_keypair, generate_wg_keypair, generate_dnstt_keypair,
                dnstt_pubkey_from_privkey, validate_dnstt_pubkey
            )
        except ImportError:
            try:
                import sys
                from pathlib import Path
                _p = (Path(__file__).resolve().parent.parent / "common").as_posix()
                if _p not in sys.path:
                    sys.path.insert(0, _p)
                from crypto_engine import (
                    P, A24, clamp, x25519, curve25519_pubkey, curve25519_reality_pubkey,
                    generate_reality_keypair, generate_wg_keypair, generate_dnstt_keypair,
                    dnstt_pubkey_from_privkey, validate_dnstt_pubkey
                )
            except Exception:
                pass
"""
src/common/crypto_engine.py - Unified RFC 7748 X25519 / Curve25519 Cryptographic Engine.

Single Source of Truth for Curve25519 key exchange, clamping, public key derivation,
and keypair generation across AmneziaWG, Reality, DNSTT, and 3X-UI panel reconciliation.
"""

import base64
import os
from typing import Optional, Tuple

P = 2**255 - 19
A24 = 121665


def clamp(k_bytes):
    """Apply RFC 7748 clamping to 32 private key bytes."""
    if len(k_bytes) != 32:
        raise ValueError(f"Expected 32 private key bytes, got {len(k_bytes)}")
    b = bytearray(k_bytes)
    b[0] &= 248
    b[31] &= 127
    b[31] |= 64
    return int.from_bytes(b, "little")


def x25519(k: int, u: int = 9) -> int:
    """RFC 7748 scalar multiplication on Curve25519 using Montgomery ladder."""
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


def curve25519_pubkey(priv_b64: str) -> Optional[str]:
    """Derive standard Base64 Curve25519 public key (AmneziaWG / WireGuard format)."""
    try:
        raw_priv = base64.b64decode(priv_b64)
        if len(raw_priv) != 32:
            return None
        k = clamp(raw_priv)
        pub_raw = x25519(k, 9).to_bytes(32, "little")
        return base64.b64encode(pub_raw).decode()
    except Exception:
        return None


def curve25519_reality_pubkey(priv_b64url: str) -> Optional[str]:
    """Derive unpadded URL-safe Base64 Curve25519 public key (Reality format)."""
    try:
        padding = "=" * ((4 - len(priv_b64url) % 4) % 4)
        raw_priv = base64.urlsafe_b64decode(priv_b64url + padding)
        if len(raw_priv) != 32:
            return None
        k = clamp(raw_priv)
        pub_raw = x25519(k, 9).to_bytes(32, "little")
        return base64.urlsafe_b64encode(pub_raw).decode().rstrip("=")
    except Exception:
        return None


def generate_reality_keypair() -> Tuple[str, str]:
    """Generate a random (private_key, public_key) pair in Reality URL-safe Base64 format."""
    priv_raw = os.urandom(32)
    k = clamp(priv_raw)
    pub_raw = x25519(k, 9).to_bytes(32, "little")
    priv_b64 = base64.urlsafe_b64encode(priv_raw).decode().rstrip("=")
    pub_b64 = base64.urlsafe_b64encode(pub_raw).decode().rstrip("=")
    return priv_b64, pub_b64


def generate_wg_keypair() -> Tuple[str, str]:
    """Generate a random (private_key, public_key) pair in standard WireGuard / AWG Base64 format."""
    priv_raw = os.urandom(32)
    k = clamp(priv_raw)
    pub_raw = x25519(k, 9).to_bytes(32, "little")
    priv_b64 = base64.b64encode(priv_raw).decode()
    pub_b64 = base64.b64encode(pub_raw).decode()
    return priv_b64, pub_b64


def generate_dnstt_keypair() -> Tuple[str, str]:
    """Generate a random (private_key_hex, public_key_hex) pair for DNSTT tunnels."""
    raw_priv = os.urandom(32)
    k = clamp(raw_priv)
    pub_hex = ((x25519(k, 9)) % P).to_bytes(32, "little").hex()
    return raw_priv.hex(), pub_hex


def dnstt_pubkey_from_privkey(priv_hex: str) -> Optional[str]:
    """Derive DNSTT public key (hex) from private key (hex)."""
    try:
        raw_priv = bytes.fromhex(priv_hex.strip())
        if len(raw_priv) != 32:
            return None
        k = clamp(raw_priv)
        return ((x25519(k, 9)) % P).to_bytes(32, "little").hex()
    except Exception:
        return None


def validate_dnstt_pubkey(pubkey: str) -> bool:
    """Validate 64-char hex string as DNSTT public key."""
    if not isinstance(pubkey, str):
        return False
    s = pubkey.strip().lower()
    return len(s) == 64 and all(c in "0123456789abcdef" for c in s)


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        cmd = sys.argv[1]
        if cmd == "wg_pubkey" and len(sys.argv) > 2:
            print(curve25519_pubkey(sys.argv[2]) or "")
        elif cmd == "wg_keypair":
            priv, pub = generate_wg_keypair()
            print(f"{priv} {pub}")
        elif cmd == "reality_pubkey" and len(sys.argv) > 2:
            print(curve25519_reality_pubkey(sys.argv[2]) or "")
        elif cmd == "reality_keypair":
            priv, pub = generate_reality_keypair()
            print(f"{priv} {pub}")
        elif cmd == "dnstt_keypair":
            priv, pub = generate_dnstt_keypair()
            if len(sys.argv) > 3:
                with open(sys.argv[2], "w", encoding="utf-8") as kf:
                    kf.write(priv + "\n")
                with open(sys.argv[3], "w", encoding="utf-8") as pf:
                    pf.write(pub + "\n")
            else:
                print(f"{priv} {pub}")
        elif cmd == "dnstt_pubkey" and len(sys.argv) > 2:
            print(dnstt_pubkey_from_privkey(sys.argv[2]) or "")

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


# ----------------- 1. Настройки панели и подписок (settings) -----------------
print("\n[+] Синхронизация системных настроек панели и подписок...")

old_sub_domain = existing_settings.get("subDomain", "").strip()
old_sub_uri = existing_settings.get("subURI", "").strip()
old_sub_path = existing_settings.get("subPath", "").strip()

requested_sub_domain = (os.environ.get("SUB_DOMAIN") or "").strip()
sub_host = requested_sub_domain or domain

# Проверка: настроена ли кастомная подписка
is_custom_sub = bool(old_sub_uri and (old_sub_domain != domain or (old_sub_path.strip("/") != sub_path and old_sub_path.strip("/") != "my-post-key")))

if requested_sub_domain and requested_sub_domain != old_sub_domain:
    # Явно запрошена смена домена подписок через CLI/Env
    clean_sub_p = sub_path.strip("/")
    target_sub_domain = requested_sub_domain
    target_sub_path = f"/{clean_sub_p}/" if clean_sub_p else "/"
    target_sub_uri = f"https://{requested_sub_domain}{target_sub_path}"
    target_sub_json_path = f"/{clean_sub_p}/json/" if clean_sub_p else "/json/"
    target_sub_json_uri = f"https://{requested_sub_domain}{target_sub_json_path}"
    target_sub_clash_path = f"/{sub_clash_path.strip('/')}/" if sub_clash_path.strip('/') else "/clash/"
    target_sub_clash_uri = f"https://{requested_sub_domain}{target_sub_clash_path}"
    print(f"  [ОБНОВЛЕНО] Домен подписок установлен: {target_sub_uri}")
elif is_custom_sub and not force_sub:
    print(f"  [СОХРАНЕНО] Кастомная подписка сохранена: {old_sub_uri}")
    target_sub_uri = old_sub_uri
    target_sub_domain = old_sub_domain
    target_sub_path = old_sub_path
    target_sub_json_path = existing_settings.get("subJsonPath") or (f"/{sub_path.strip('/')}/json/" if sub_path.strip('/') else "/json/")
    target_sub_json_uri = existing_settings.get("subJsonURI") or f"https://{sub_host}{target_sub_json_path}"
    target_sub_clash_path = existing_settings.get("subClashPath") or (f"/{sub_clash_path.strip('/')}/" if sub_clash_path.strip('/') else "/clash/")
    if target_sub_clash_path.strip("/") == f"{sub_path}clash":
        target_sub_clash_path = f"/{sub_clash_path.strip('/')}/" if sub_clash_path.strip('/') else "/clash/"
    target_sub_clash_uri = existing_settings.get("subClashURI") or f"https://{sub_host}{target_sub_clash_path}"
    if target_sub_clash_uri.endswith(f"{sub_path}clash/"):
        target_sub_clash_uri = f"https://{sub_host}{target_sub_clash_path}"
else:
    clean_sub_p = sub_path.strip("/")
    target_sub_domain = sub_host
    target_sub_path = f"/{clean_sub_p}/" if clean_sub_p else "/"
    target_sub_uri = f"https://{sub_host}{target_sub_path}"
    target_sub_json_path = f"/{clean_sub_p}/json/" if clean_sub_p else "/json/"
    target_sub_json_uri = f"https://{sub_host}{target_sub_json_path}"
    target_sub_clash_path = f"/{sub_clash_path.strip('/')}/" if sub_clash_path.strip('/') else "/clash/"
    target_sub_clash_uri = f"https://{sub_host}{target_sub_clash_path}"

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
    "webBasePath": f"/{panel_path}/" if panel_path else "/",
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

# ----------------- 1.0. Интеграция Mieru в шаблон подписки Clash (subClashTemplate) -----------------
enable_mieru = os.environ.get("ENABLE_MIERU", "n").lower() in ("1", "y", "true") or os.path.exists("/etc/systemd/system/mita.service") or os.path.exists("/etc/mita/config.json")
mieru_port_mode = (os.environ.get("MIERU_PORT_MODE") or "single").strip().lower()
mieru_port = (os.environ.get("MIERU_PORT") or ("8450-8455" if mieru_port_mode == "range" else "8450")).strip()
mieru_transport = (os.environ.get("MIERU_TRANSPORT") or "").strip().upper()
mieru_user = (os.environ.get("MIERU_USER") or "").strip()
mieru_pass = (os.environ.get("MIERU_PASS") or "").strip()

if enable_mieru and (not mieru_user or not mieru_pass or not mieru_transport):
    for m_cfg_candidate in ["/etc/mita/config.json", "/etc/mita_server_config.json"]:
        if os.path.isfile(m_cfg_candidate):
            try:
                with open(m_cfg_candidate, "r", encoding="utf-8") as mf:
                    mdata = json.load(mf)
                    if not mieru_user and mdata.get("users") and len(mdata["users"]) > 0:
                        mieru_user = mdata["users"][0].get("name", "")
                    if not mieru_pass and mdata.get("users") and len(mdata["users"]) > 0:
                        mieru_pass = mdata["users"][0].get("password", "")
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

if enable_mieru and mieru_user and mieru_pass:
    server_title = (sub_title or domain or "VPN").strip()
    mieru_node_name = f"{server_title} — Mieru"
    if mieru_port_mode == "range" or "-" in mieru_port:
        m_port_field = f"port-range: {mieru_port}"
    else:
        m_port_clean = mieru_port.split("-")[0].split(":")[0]
        m_port_field = f"port: {m_port_clean}"

    safe_node_name = json.dumps(mieru_node_name)
    safe_user = json.dumps(mieru_user)
    safe_pass = json.dumps(mieru_pass)
    clash_transport = "UDP" if mieru_transport == "UDP" else "TCP"
    mieru_yaml_block = f"""  - name: {safe_node_name}
    type: mieru
    server: {domain}
    {m_port_field}
    transport: {clash_transport}
    udp: true
    username: {safe_user}
    password: {safe_pass}
    multiplexing: MULTIPLEXING_LOW
    handshake-mode: HANDSHAKE_STANDARD"""

    raw_clash_tpl = existing_settings.get("subClashTemplate", "")
    if not raw_clash_tpl or not raw_clash_tpl.strip():
        new_clash_tpl = f"""port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
unified-delay: true
global-client-fingerprint: chrome
dns:
  enable: true
  listen: :1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver:
    - 1.1.1.1
    - 8.8.8.8
  nameserver:
    - https://dns.google/dns-query
    - https://1.1.1.1/dns-query
proxies:
{mieru_yaml_block}
proxy-groups:
  - name: "PROXIES"
    type: select
    proxies:
      - "{mieru_node_name}"
  - name: "AUTO"
    type: url-test
    url: http://www.gstatic.com/generate_204
    interval: 300
    proxies:
      - "{mieru_node_name}"
rules:
  - GEOIP,private,DIRECT
  - MATCH,PROXIES
"""
    elif "type: mieru" not in raw_clash_tpl:
        lines = raw_clash_tpl.splitlines()
        new_lines = []
        proxies_injected = False
        has_proxies = any(l.strip().startswith("proxies:") for l in lines)
        if not has_proxies:
            new_lines.append("proxies:")
            new_lines.append(mieru_yaml_block)
            new_lines.extend(lines)
        else:
            for l in lines:
                new_lines.append(l)
                if not proxies_injected and l.strip().startswith("proxies:"):
                    new_lines.append(mieru_yaml_block)
                    proxies_injected = True
        
        final_lines = []
        in_tg = False
        for l in new_lines:
            final_lines.append(l)
            if re.search(r'name:\s*["\']?(PROXIES|AUTO|PROXY|Default|FALLBACK)["\']?', l, re.IGNORECASE):
                in_tg = True
            elif in_tg and l.strip().startswith("proxies:"):
                final_lines.append(f'      - "{mieru_node_name}"')
                in_tg = False
            elif in_tg and l.strip() and not l.startswith(" ") and not l.startswith("\t"):
                in_tg = False
        new_clash_tpl = "\n".join(final_lines) + "\n"
    else:
        new_clash_tpl = raw_clash_tpl

    if new_clash_tpl != raw_clash_tpl:
        if not dry_run:
            cur.execute("SELECT id FROM settings WHERE key = 'subClashTemplate'")
            if cur.fetchone():
                cur.execute("UPDATE settings SET value = ? WHERE key = 'subClashTemplate'", (new_clash_tpl,))
            else:
                cur.execute("INSERT INTO settings (key, value) VALUES ('subClashTemplate', ?)", (new_clash_tpl,))
        print(f"  [ИСПРАВЛЕНО] Узел Mieru ({mieru_port}) интегрирован в шаблон подписки subClashTemplate.")

# ----------------- 1.1. Тюнинг безопасности и шаблона ядра Xray (xrayTemplateConfig) -----------------
print("\n[+] Синхронизация шаблона конфигурации Xray (DNS, безопасность и защита от абуз)...")

enable_warp = os.environ.get("ENABLE_WARP", "n").lower() in ("1", "y", "true")
warp_license_key = os.environ.get("WARP_LICENSE_KEY", "").strip()

# ----------------- Шаблон ядра Xray и правила маршрутизации -----------------

DEFAULT_XRAY_TEMPLATE = {
    "api": {
        "services": ["HandlerService", "LoggerService", "StatsService", "RoutingService"],
        "tag": "api"
    },
    "inbounds": [{
        "listen": "127.0.0.1", "port": 62789, "protocol": "tunnel",
        "settings": {"rewriteAddress": "127.0.0.1"}, "tag": "api"
    }],
    "log": {"access": "none", "dnsLog": False, "error": "", "loglevel": "warning", "maskAddress": ""},
    "metrics": {"listen": "127.0.0.1:11111", "tag": "metrics_out"},
    "outbounds": [
        {"protocol": "freedom", "settings": {"domainStrategy": "AsIs"}, "tag": "direct"},
        {"protocol": "blackhole", "settings": {}, "tag": "blocked"}
    ],
    "policy": {
        "levels": {"0": {"statsUserDownlink": True, "statsUserUplink": True}},
        "system": {"statsInboundDownlink": True, "statsInboundUplink": True, "statsOutboundDownlink": False, "statsOutboundUplink": False}
    },
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {"inboundTag": ["api"], "outboundTag": "api", "type": "field"},
            {"ip": ["geoip:private"], "outboundTag": "blocked", "type": "field"}
        ]
    },
    "stats": {}
}

BAD_GEOSITES = {
    "geosite:ru", "geosite:yandex", "geosite:vk", "geosite:youtube",
    "geosite:openai", "geosite:google-gemini", "geosite:anthropic", "geosite:cloudflare"
}

YT_DOMAINS = [
    "domain:youtube.com",
    "domain:googlevideo.com",
    "domain:ytimg.com",
    "domain:youtu.be",
    "domain:youtubei.googleapis.com",
    "domain:yt.be"
]

RU_DOMAINS = [
    "domain:ru",
    "domain:su",
    "domain:рф",
    "domain:xn--p1ai",
    "domain:yandex.ru",
    "domain:yandex.net",
    "domain:ya.ru",
    "domain:vk.com",
    "domain:vk.ru",
    "domain:vkvideo.ru",
    "domain:gosuslugi.ru",
    "domain:sberbank.ru",
    "domain:tbank.ru",
    "domain:tinkoff.ru",
    "domain:dzen.ru",
    "domain:mail.ru",
    "domain:rutube.ru",
    "domain:ozon.ru",
    "domain:wildberries.ru",
    "domain:avito.ru"
]

WARP_DOMAINS = [
    "domain:openai.com",
    "domain:chatgpt.com",
    "domain:oaistatic.com",
    "domain:oaiusercontent.com",
    "domain:anthropic.com",
    "domain:claude.ai",
    "domain:gemini.google.com",
    "domain:aistudio.google.com",
    "domain:deepmind.google",
    "domain:makersuite.google.com",
    "domain:generativelanguage.googleapis.com",
    "domain:ai.google.dev",
    "domain:google.com",
    "domain:cloudflare.com",
    "domain:challenges.cloudflare.com"
]

# Чтение и инициализация шаблона Xray
raw_tpl = existing_settings.get("xrayTemplateConfig")
tpl = None
if raw_tpl:
    try:
        tpl = json.loads(raw_tpl)
    except Exception:
        pass
if not tpl or not isinstance(tpl, dict):
    tpl = json.loads(json.dumps(DEFAULT_XRAY_TEMPLATE))

# 1. DNS: UseIPv4 стратегия для предотвращения задержек AAAA
dns_cfg = tpl.get("dns", {})
if not isinstance(dns_cfg, dict):
    dns_cfg = {}
if dns_cfg.get("queryStrategy") != "UseIPv4":
    dns_cfg["queryStrategy"] = "UseIPv4"
    print("  [ОБНОВЛЕН] DNS queryStrategy: зафиксирован 'UseIPv4' (устранение задержек IPv6).")
else:
    print("  [В ПОРЯДКЕ] DNS queryStrategy: 'UseIPv4'.")

enable_agh = os.environ.get("ENABLE_AGH", "").lower() in ("1", "y", "true")
agh_xray_dns = os.environ.get("AGH_XRAY_DNS", "").lower() in ("1", "y", "true")
if enable_agh and agh_xray_dns:
    agh_dns_port = int(os.environ.get("PORT_AGH_DNS") or "10053")
    target_servers = [{"address": "127.0.0.1", "port": agh_dns_port}]
    if dns_cfg.get("servers") != target_servers:
        dns_cfg["servers"] = target_servers
        print(f"  [ОБНОВЛЕН] DNS servers: зафиксирован '127.0.0.1:{agh_dns_port}' (AdGuard Home локальный фильтр).")
    else:
        print(f"  [В ПОРЯДКЕ] DNS servers: '127.0.0.1:{agh_dns_port}' (AdGuard Home).")
tpl["dns"] = dns_cfg

# 2. Логирование (тихий безопасный режим, без записи посещаемых URL)
log_cfg = tpl.get("log", {})
if not isinstance(log_cfg, dict):
    log_cfg = {}
log_cfg["loglevel"] = log_cfg.get("loglevel") or "warning"
log_cfg["dnsLog"] = False
if "access" not in log_cfg:
    log_cfg["access"] = "none"
tpl["log"] = log_cfg

# 3. Гарантируем наличие blackhole outbound 'blocked'
outbounds = tpl.get("outbounds", [])
if not isinstance(outbounds, list):
    outbounds = []
has_blocked_ob = any(isinstance(ob, dict) and ob.get("tag") == "blocked" for ob in outbounds)
if not has_blocked_ob:
    outbounds.append({"protocol": "blackhole", "settings": {}, "tag": "blocked"})
    print("  [СОЗДАНО] Outbound 'blocked' (blackhole) добавлен в шаблон.")
tpl["outbounds"] = outbounds

# 4. Правила маршрутизации: Блокировка SMTP (порт 25) и приватных сетей (SSRF)
routing = tpl.get("routing", {})
if not isinstance(routing, dict):
    routing = {}
rules = routing.get("rules", [])
if not isinstance(rules, list):
    rules = []

# А. Блокировка спама (строго порт 25, не затрагивая клиентские 465/587)
if block_smtp:
    has_smtp_block = any(
        isinstance(r, dict) and r.get("outboundTag") == "blocked" and "25" in str(r.get("port", "")).split(",")
        for r in rules
    )
    if not has_smtp_block:
        rules.insert(0, {
            "type": "field",
            "port": "25",
            "outboundTag": "blocked"
        })
        print("  [СОЗДАНО] Защита от спама: исходящий порт 25 заблокирован (outboundTag: blocked).")
    else:
        print("  [В ПОРЯДКЕ] Защита от спама: порт 25 уже заблокирован.")

# Б. Блокировка доступа к приватным IP и хосту (SSRF защита)
if block_lan:
    lan_ips = ["geoip:private", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "fc00::/7", "fe80::/10"]
    has_lan_block = any(
        isinstance(r, dict) and r.get("outboundTag") == "blocked" and any(ip_elem in str(r.get("ip", [])) for ip_elem in ["geoip:private", "127.0.0.0/8", "10.0.0.0/8"])
        for r in rules
    )
    if not has_lan_block:
        rules.insert(0, {
            "type": "field",
            "ip": lan_ips,
            "outboundTag": "blocked"
        })
        print("  [СОЗДАНО] SSRF-защита: доступ к приватным IP хоста заблокирован (outboundTag: blocked).")
    else:
        print("  [В ПОРЯДКЕ] SSRF-защита: локальные сети уже изолированы.")

routing["rules"] = rules
tpl["routing"] = routing

# 5. Опциональная интеграция Cloudflare WARP и выборочной маршрутизации
if enable_warp:
    print("\n[+] Интеграция Cloudflare WARP (Outbound WireGuard, MTU: 1280 & Smart Routing)...")
    warp_data = {}
    if existing_settings.get("warpData"):
        try:
            warp_data = json.loads(existing_settings["warpData"])
        except Exception:
            warp_data = {}

    priv_b64 = warp_data.get("private_key")
    device_id = warp_data.get("device_id")
    client_id = warp_data.get("client_id", "")
    token = warp_data.get("access_token", "")
    endpoint_host = "162.159.192.1:2408"
    v4_address = "172.16.0.2/32"
    v6_address = "2606:4700:110:8780:4178:f4a4:a997:2167/128"
    peer_pub = "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

    if priv_b64 and device_id:
        print(f"  [СОХРАНЕНО] Действующий аккаунт WARP (Device ID: {device_id})")
    elif dry_run:
        print("  [DRY-RUN] Регистрация WARP пропущена (холостой прогон)")
        priv_b64, pub_b64 = "dryrun-privkey", "dryrun-pubkey"
        device_id, token, client_id = "dryrun-device", "dryrun-token", ""
    else:
        # Регистрация нового аккаунта через официальный API Cloudflare
        priv_b64, pub_b64 = generate_wg_keypair()
        reg_payload = {
            "key": pub_b64,
            "tos": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
            "type": "PC",
            "model": "x-ui",
            "name": "x-ui"
        }
        reg_req = urllib.request.Request(
            "https://api.cloudflareclient.com/v0a4005/reg",
            data=json.dumps(reg_payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "CF-Client-Version": "a-6.30-3596",
                "User-Agent": "okhttp/3.12.1"
            },
            method="POST"
        )
        try:
            with urllib.request.urlopen(reg_req, timeout=12) as reg_resp:
                reg_res = json.loads(reg_resp.read().decode("utf-8"))
            device_id = reg_res.get("id", "")
            token = reg_res.get("token", "")
            cfg = reg_res.get("config", {})
            client_id = cfg.get("client_id", "")
            peers = cfg.get("peers", [])
            if peers:
                peer_pub = peers[0].get("public_key", peer_pub)
                peer_ep_data = peers[0].get("endpoint", {})
                if isinstance(peer_ep_data, dict) and peer_ep_data.get("host"):
                    endpoint_host = peer_ep_data["host"]
            addrs = cfg.get("interface", {}).get("addresses", {})
            if addrs.get("v4"):
                v4_address = f"{addrs['v4']}/32"
            if addrs.get("v6"):
                v6_address = f"{addrs['v6']}/128"

            # Опциональная привязка лицензии WARP+
            if warp_license_key and device_id and token:
                try:
                    lic_req = urllib.request.Request(
                        f"https://api.cloudflareclient.com/v0a4005/reg/{device_id}/account",
                        data=json.dumps({"license": warp_license_key}).encode("utf-8"),
                        headers={
                            "Content-Type": "application/json",
                            "Authorization": f"Bearer {token}",
                            "User-Agent": "okhttp/3.12.1"
                        },
                        method="PUT"
                    )
                    with urllib.request.urlopen(lic_req, timeout=10) as lic_resp:
                        pass
                    print("  [АКТИВИРОВАНО] Лицензия WARP+ успешно привязана к аккаунту.")
                except Exception as e_lic:
                    print(f"  [!] Не удалось привязать ключ WARP+: {e_lic}")

            warp_data = {
                "access_token": token,
                "device_id": device_id,
                "license_key": warp_license_key,
                "private_key": priv_b64,
                "client_id": client_id
            }
            if not dry_run:
                for wk, wv in [("warpData", json.dumps(warp_data)), ("warpUpdateInterval", "0"), ("warpLastUpdate", str(int(time.time())))]:
                    cur.execute("SELECT id FROM settings WHERE key = ?", (wk,))
                    if cur.fetchone():
                        cur.execute("UPDATE settings SET value = ? WHERE key = ?", (wv, wk))
                    else:
                        cur.execute("INSERT INTO settings (key, value) VALUES (?, ?)", (wk, wv))
            print(f"  [СОЗДАНО] Cloudflare WARP аккаунт зарегистрирован (Device ID: {device_id})")
        except Exception as e_reg:
            print(f"  [!] Предупреждение: Cloudflare API недоступен ({e_reg}).")
            print("      Шаблон Xray сконфигурирован с MTU 1280. Регистрацию можно завершить в 1 клик в панели 3X-UI.")
            warp_data = {"private_key": priv_b64, "client_id": ""}

    # Декодирование reserved bytes
    reserved = [0, 0, 0]
    if client_id:
        try:
            dec = list(base64.b64decode(client_id))
            if len(dec) >= 3:
                reserved = dec[:3]
        except Exception:
            pass

    # Формирование объекта outbound 'warp'
    warp_outbound = {
        "tag": "warp",
        "protocol": "wireguard",
        "settings": {
            "secretKey": priv_b64,
            "address": [v4_address, v6_address] if v6_address else [v4_address],
            "peers": [
                {
                    "publicKey": peer_pub,
                    "endpoint": endpoint_host
                }
            ],
            "reserved": reserved,
            "mtu": 1280
        }
    }

    # Согласование outbounds WARP
    outbounds = tpl.get("outbounds", [])
    warp_ob_idx = -1
    for i, ob in enumerate(outbounds):
        if isinstance(ob, dict) and ob.get("tag") == "warp":
            warp_ob_idx = i
            break

    if warp_ob_idx >= 0:
        existing_ob = outbounds[warp_ob_idx]
        ob_settings = existing_ob.get("settings", {})
        ob_settings["mtu"] = 1280
        if not ob_settings.get("secretKey") and priv_b64:
            ob_settings["secretKey"] = priv_b64
        if not ob_settings.get("reserved") and reserved != [0, 0, 0]:
            ob_settings["reserved"] = reserved
        outbounds[warp_ob_idx] = existing_ob
        print("  [ОБНОВЛЕН] Outbound 'warp': зафиксирован MTU 1280 и проверены ключи WireGuard.")
    else:
        outbounds.append(warp_outbound)
        print("  [СОЗДАНО] Outbound 'warp' (WireGuard, MTU: 1280) добавлен в шаблон Xray.")
    tpl["outbounds"] = outbounds

    # Маршрутизация WARP
    routing = tpl.get("routing", {})
    rules = routing.get("rules", [])

    bad_geosites = BAD_GEOSITES

    # Очистка всех существующих правил от отсутствующих/невалидных geosite меток
    for r in rules:
        if isinstance(r, dict) and "domain" in r and isinstance(r["domain"], list):
            r["domain"] = [d for d in r["domain"] if d not in bad_geosites]

    yt_domains = YT_DOMAINS
    ru_domains = RU_DOMAINS
    warp_domains = WARP_DOMAINS

    # 1. Из правил WARP исключаем любые YouTube домены
    for r in rules:
        if isinstance(r, dict) and r.get("outboundTag") == "warp":
            if "domain" in r and isinstance(r["domain"], list):
                r["domain"] = [d for d in r["domain"] if not any(y in str(d).lower() for y in ["youtube", "googlevideo", "ytimg", "youtu.be"])]

    # 2. Обработка и нормализация существующих правил
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
        # Direct-правило для RU: разделяем domain и ip с сохранением пользовательских ограничений
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
            continue
        cleaned_existing_rules.append(r)

    new_rules = []
    # 1. Системные правила (api, blocked)
    for r in cleaned_existing_rules:
        if r.get("outboundTag") in ("api", "blocked"):
            new_rules.append(r)

    # 2. YouTube -> Direct (СТРОГО ВЫШЕ WARP)
    if not yt_rule:
        yt_rule = {
            "type": "field",
            "outboundTag": "direct",
            "domain": yt_domains
        }
        print("  [СОЗДАНО] Маршрут YouTube -> DIRECT (без задержек и буферизации).")
    new_rules.append(yt_rule)

    # 3. RU -> Direct (раздельные независимые правила)
    if not ru_domain_rule:
        ru_domain_rule = {
            "type": "field",
            "outboundTag": "direct",
            "domain": ru_domains
        }
    new_rules.append(ru_domain_rule)

    if not ru_ip_rule:
        ru_ip_rule = {
            "type": "field",
            "outboundTag": "direct",
            "ip": ["geoip:ru"]
        }
    new_rules.append(ru_ip_rule)
    print("  [СОЗДАНО/ОБНОВЛЕНО] Маршруты RU-доменов и RU-IP -> DIRECT (раздельные независимые правила).")

    # 4. WARP правило (после direct правил YouTube и RU)
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
        print("  [СОЗДАНО] Маршрут Google, Gemini, OpenAI, Claude -> WARP (обход капч и AI).")
    new_rules.append(warp_rule)

    # 5. Остальные пользовательские правила
    for r in cleaned_existing_rules:
        if r not in new_rules and r.get("outboundTag") != "warp":
            new_rules.append(r)

    routing["rules"] = new_rules
    tpl["routing"] = routing
else:
    print("\n[-] Исходящий туннель Cloudflare WARP отключен в конфигурации.")

# Очистка всех потенциально опасных / отсутствующих geosite из всех маршрутов шаблона
bad_geosites = {
    "geosite:ru", "geosite:yandex", "geosite:vk", "geosite:youtube",
    "geosite:openai", "geosite:google-gemini", "geosite:anthropic", "geosite:cloudflare"
}
routing = tpl.get("routing", {})
if isinstance(routing, dict):
    clean_rules = []
    for r in routing.get("rules", []):
        if isinstance(r, dict):
            if "domain" in r and isinstance(r["domain"], list):
                r["domain"] = [d for d in r["domain"] if d not in bad_geosites]
                if not r["domain"] and not r.get("ip") and not r.get("port"):
                    continue
            clean_rules.append(r)
    routing["rules"] = clean_rules
    tpl["routing"] = routing

# Сохранение обновленного шаблона xrayTemplateConfig
new_xray_json = json.dumps(tpl, indent=2, ensure_ascii=False)
if not dry_run:
    cur.execute("SELECT id FROM settings WHERE key = 'xrayTemplateConfig'")
    if cur.fetchone():
        cur.execute("UPDATE settings SET value = ? WHERE key = 'xrayTemplateConfig'", (new_xray_json,))
    else:
        cur.execute("INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', ?)", (new_xray_json,))
print("  [ИСПРАВЛЕНО] Конфигурация xrayTemplateConfig синхронизирована и сохранена в базе данных.")

# ----------------- 2. Интеллектуальное согласование инбаундов (Smart Reconcile) -----------------
print("\n[+] Аудит и согласование инбаундов (Smart Reconcile Engine)...")

# --- Единый клиент для всех протоколов и инбаундов (консолидация реестра) ---
client_email_env = os.environ.get("CLIENT_EMAIL", "").strip() or os.environ.get("CLIENT_NAME", "").strip()
safe_prefix_clean = re.sub(r'[^a-zA-Z0-9_-]', '', server_prefix) if server_prefix else ""
unified_email = client_email_env or (f"Client-{safe_prefix_clean}" if safe_prefix_clean and safe_prefix_clean.lower() != "server" else "Client")

# Регулярное выражение для поиска устаревших раздельных клиентов (Client-Steal, Client-Classic и т.п.)
obsolete_pattern = re.compile(r'-(steal|steal-backup|steal-compat|classic|xhttp|hy2|hysteria|hysteria2|awg-v3|awg-v2)$', re.IGNORECASE)

# Сканирование и сбор существующих реквизитов (UUID, subId, пароли, ключи) для бесшовного обновления
harvested_uuid = None
harvested_sub_id = None
harvested_hy2_pass = None
harvested_wg_c_priv = None
harvested_wg_c_pub = None
harvested_wg_hpk = None
harvested_ss_server_pass = None
harvested_ss_client_pass = None
harvested_tuic_uuid = None
harvested_tuic_pass = None
harvested_mtp_secret = None
harvested_mtp_adtag = None
harvested_vless_dekey = None
harvested_vless_enkey = None

if "clients" in all_tables and "email" in clients_cols:
    cand_cols = ["uuid", "sub_id", "password", "wg_private_key", "wg_public_key", "secret", "ad_tag", "encryption"]
    avail_cols = [c for c in cand_cols if c in clients_cols]
    if avail_cols:
        col_list = ", ".join(avail_cols)
        cur.execute(f"SELECT {col_list} FROM clients WHERE email = ?", (unified_email,))
        row_c = cur.fetchone()
        if row_c:
            c_map = dict(zip(avail_cols, row_c))
            if c_map.get("uuid"): harvested_uuid = c_map["uuid"]
            if c_map.get("sub_id"): harvested_sub_id = c_map["sub_id"]
            if c_map.get("password"): harvested_hy2_pass = c_map["password"]
            if c_map.get("wg_private_key"): harvested_wg_c_priv = c_map["wg_private_key"]
            if c_map.get("wg_public_key"): harvested_wg_c_pub = c_map["wg_public_key"]
            if c_map.get("secret"): harvested_mtp_secret = c_map["secret"]
            if c_map.get("ad_tag"): harvested_mtp_adtag = c_map["ad_tag"]
            if c_map.get("encryption"): harvested_vless_enkey = c_map["encryption"]

harvested_reality_priv = None
harvested_reality_pub = None
harvested_reality_sids = None

cur.execute("SELECT port, protocol, settings, stream_settings FROM inbounds")
for p, proto, raw_s, raw_st in cur.fetchall():
    try:
        s_obj = json.loads(raw_s) if raw_s else {}
    except Exception:
        continue
    c_list = s_obj.get("clients", [])
    if c_list and isinstance(c_list, list) and len(c_list) > 0:
        for c_cand in c_list:
            c_cand_email = c_cand.get("email") or c_cand.get("Email")
            if c_cand_email == unified_email:
                if proto == "vless":
                    if not harvested_uuid and c_cand.get("id"): harvested_uuid = c_cand.get("id")
                    if not harvested_sub_id and c_cand.get("subId"): harvested_sub_id = c_cand.get("subId")
                elif proto == "hysteria":
                    if not harvested_hy2_pass and (c_cand.get("id") or c_cand.get("password") or c_cand.get("auth")):
                        harvested_hy2_pass = c_cand.get("id") or c_cand.get("password") or c_cand.get("auth")
                elif proto == "shadowsocks":
                    if not harvested_ss_client_pass and c_cand.get("password"):
                        harvested_ss_client_pass = c_cand.get("password")
                elif proto == "tuic":
                    if not harvested_tuic_uuid and c_cand.get("uuid"):
                        harvested_tuic_uuid = c_cand.get("uuid")
                    elif not harvested_tuic_uuid and c_cand.get("id"):
                        harvested_tuic_uuid = c_cand.get("id")
                    if not harvested_tuic_pass and c_cand.get("password"):
                        harvested_tuic_pass = c_cand.get("password")
                elif proto == "mtproto":
                    if not harvested_mtp_secret and c_cand.get("secret"):
                        harvested_mtp_secret = c_cand.get("secret")
                    if not harvested_mtp_adtag and (c_cand.get("ad_tag") or c_cand.get("adTag")):
                        harvested_mtp_adtag = c_cand.get("ad_tag") or c_cand.get("adTag")
                elif proto == "amneziawg":
                    if not harvested_wg_c_priv and c_cand.get("privateKey"):
                        harvested_wg_c_priv = c_cand.get("privateKey")
                        harvested_wg_c_pub = c_cand.get("publicKey")
                    srv_conf = s_obj.get("server", {})
                    if srv_conf.get("headerProtectionKey") and not harvested_wg_hpk:
                        harvested_wg_hpk = srv_conf["headerProtectionKey"]
    if proto == "vless":
        if s_obj.get("decryption") and s_obj["decryption"] != "none":
            if not harvested_vless_dekey: harvested_vless_dekey = s_obj["decryption"]
            if not harvested_vless_enkey and s_obj.get("encryption"):
                harvested_vless_enkey = s_obj["encryption"]
        if not harvested_vless_enkey and c_list:
            for _c in c_list:
                if _c.get("encryption"):
                    harvested_vless_enkey = _c["encryption"]
                    break
    if proto == "shadowsocks":
        if not harvested_ss_server_pass and s_obj.get("password"):
            harvested_ss_server_pass = s_obj.get("password")
    if raw_st and not harvested_reality_priv:
        try:
            st_obj = json.loads(raw_st)
            r_set = st_obj.get("realitySettings", {})
            if r_set.get("privateKey"):
                harvested_reality_priv = r_set.get("privateKey")
                harvested_reality_pub = r_set.get("settings", {}).get("publicKey") or r_set.get("publicKey") or curve25519_reality_pubkey(harvested_reality_priv)
                if r_set.get("shortIds"):
                    harvested_reality_sids = r_set.get("shortIds")
        except Exception:
            pass

# Итоговые эталонные согласованные реквизиты единого клиента
unified_uuid = harvested_uuid or str(uuid.uuid4())
unified_sub_id = harvested_sub_id or secrets.token_hex(8)
unified_hy2_pass = harvested_hy2_pass or secrets.token_hex(12)

# Реквизиты Shadowsocks 2022
ss_method = "2022-blake3-aes-256-gcm"
if not regen_server_keys and harvested_ss_server_pass and validate_ss2022_key(harvested_ss_server_pass, ss_method):
    unified_ss_server_pass = harvested_ss_server_pass
else:
    unified_ss_server_pass = generate_ss2022_key(ss_method)
    if regen_server_keys:
        print(f"  [ОБНОВЛЕНО] Сгенерирован новый серверный мастер-ключ Shadowsocks-2022")

if not regen_server_keys and harvested_ss_client_pass and validate_ss2022_key(harvested_ss_client_pass, ss_method):
    unified_ss_client_pass = harvested_ss_client_pass
else:
    unified_ss_client_pass = generate_ss2022_key(ss_method)

# Реквизиты TUIC v5
unified_tuic_uuid = harvested_tuic_uuid or unified_uuid
# ВАЖНО: Пароль TUIC v5 должен строго совпадать с clients.password (unified_ss_client_pass),
# чтобы прямая ссылка tuic:// и экспорт подписки Clash/Mihomo содержали один и тот же пароль
unified_tuic_pass = unified_ss_client_pass
tuic_cert, tuic_key = resolve_cert_key_paths(domain, os.environ.get("TUIC_CERT_PATH", ""), os.environ.get("TUIC_KEY_PATH", ""))

# Реквизиты Telegram MTProxy
if not regen_server_keys and harvested_mtp_secret and validate_mtproto_secret(harvested_mtp_secret):
    unified_mtp_secret = harvested_mtp_secret
else:
    unified_mtp_secret = generate_mtproto_secret(mtproto_faketls_domain)
    if regen_server_keys:
        print(f"  [ОБНОВЛЕНО] Сгенерирован новый FakeTLS секрет Telegram MTProxy")

unified_mtp_adtag = mtproto_adtag or harvested_mtp_adtag or ""
if unified_mtp_adtag and not validate_mtproto_adtag(unified_mtp_adtag):
    unified_mtp_adtag = ""

if harvested_reality_priv and not regen_server_keys:
    def_reality_priv = harvested_reality_priv
    def_reality_pub = harvested_reality_pub or curve25519_reality_pubkey(def_reality_priv)
    def_reality_sids = harvested_reality_sids or ([unified_sub_id] + [secrets.token_hex(n) for n in (1, 2, 3, 6)])
    print(f"  [СОХРАНЕНО] Серверные ключи VLESS-REALITY сохранены из базы SQLite")
else:
    def_reality_priv, def_reality_pub = generate_reality_keypair()
    def_reality_sid = unified_sub_id
    def_reality_sids = [def_reality_sid] + [secrets.token_hex(n) for n in (1, 2, 3, 6)]
    if regen_server_keys:
        print(f"  [ОБНОВЛЕНО] Сгенерированы новые серверные ключи VLESS-REALITY (x25519)")

def_wg_s_priv, def_wg_s_pub = generate_wg_keypair()
if harvested_wg_c_priv and harvested_wg_c_pub:
    def_wg_c_priv, def_wg_c_pub = harvested_wg_c_priv, harvested_wg_c_pub
else:
    def_wg_c_priv, def_wg_c_pub = generate_wg_keypair()

# AWG v3.1: Защита заголовков Handshake (HeaderProtectionKey) и RandomTrailers
unified_awg_hpk = awg_hpk_env or harvested_wg_hpk or base64.b64encode(secrets.token_bytes(32)).decode()
unified_awg_random_trailers = awg_random_trailers_env

# Защита от потери данных: деструктивное удаление клиентов (DELETE FROM clients) заблокировано
obsolete_emails = []
print(f"  [ЕДИНЫЙ КЛИЕНТ] Профиль: '{unified_email}' (привязка ко всем инбаундам, subId: {unified_sub_id[:6]}...)")

def smart_reconcile_inbound(port, protocol, tag, remark, default_settings, default_stream, listen="127.0.0.1", enabled=True):
    inb_cols = globals().get("inbounds_cols")
    if inb_cols is None:
        try:
            cur.execute("PRAGMA table_info(inbounds)")
            inb_cols = set(r[1] for r in cur.fetchall())
        except Exception:
            inb_cols = set()

    tr_col = "traffic_reset" if "traffic_reset" in inb_cols else ("trafficReset" if "trafficReset" in inb_cols else None)
    trd_col = "traffic_reset_day" if "traffic_reset_day" in inb_cols else ("trafficResetDay" if "trafficResetDay" in inb_cols else None)
    ltrt_col = "last_traffic_reset_time" if "last_traffic_reset_time" in inb_cols else ("lastTrafficResetTime" if "lastTrafficResetTime" in inb_cols else None)

    target_tr = globals().get("inbound_traffic_reset", "monthly")
    target_tr_day = globals().get("inbound_traffic_reset_day", 1)

    cur.execute("SELECT id, settings, stream_settings, protocol, tag, remark, listen, enable FROM inbounds WHERE port = ? OR tag = ?", (port, tag))
    row = cur.fetchone()
    
    if not row:
        # Инбаунд отсутствует -> создаем под ключ
        target_settings = json.loads(json.dumps(default_settings))
        target_stream = json.loads(json.dumps(default_stream))
        if protocol == "mtproto" and "preferIp" not in target_settings:
            target_settings["preferIp"] = "prefer-ipv4"
        if "externalProxy" in target_stream and isinstance(target_stream["externalProxy"], list) and len(target_stream["externalProxy"]) > 0:
            for ep in target_stream["externalProxy"]:
                if protocol in ("shadowsocks", "mtproto", "amneziawg"):
                    ep["forceTls"] = "none"
                elif protocol == "vless" and "realitySettings" in target_stream:
                    ep["forceTls"] = "same"
                elif "forceTls" not in ep:
                    ep["forceTls"] = "tls"
                if "alpn" in ep and isinstance(ep["alpn"], str):
                    ep["alpn"] = [ep["alpn"]] if ep["alpn"] else []

        settings_json = json.dumps(target_settings, ensure_ascii=False)
        stream_json = json.dumps(target_stream, ensure_ascii=False)
        sniffing_json = json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"]})
        new_inbound_id = None
        if not dry_run:
            ib_data = {
                "user_id": admin_id,
                "up": 0,
                "down": 0,
                "total": 0,
                "remark": remark,
                "enable": 1 if enabled else 0,
                "expiry_time": 0,
                "listen": listen,
                "port": port,
                "protocol": protocol,
                "settings": settings_json,
                "stream_settings": stream_json,
                "tag": tag,
                "sniffing": sniffing_json,
            }
            if tr_col:
                ib_data[tr_col] = target_tr
            if trd_col:
                ib_data[trd_col] = target_tr_day
            if ltrt_col:
                ib_data[ltrt_col] = 0

            if inb_cols:
                valid_ib = {k: v for k, v in ib_data.items() if k in inb_cols}
            else:
                valid_ib = {k: v for k, v in ib_data.items() if not k.startswith("traffic") and not k.startswith("last_traffic")}

            cols_str = ", ".join(valid_ib.keys())
            placeholders = ", ".join(["?"] * len(valid_ib))
            cur.execute(f"INSERT INTO inbounds ({cols_str}) VALUES ({placeholders})", list(valid_ib.values()))
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
    target_snis = []
    old_snis = []

    # Сохранение пользовательского названия инбаунда (remark), если оно было изменено
    final_remark = remark
    force_remarks_flag = globals().get("force_remarks", False)
    if not force_remarks_flag and cur_remark and str(cur_remark).strip():
        final_remark = str(cur_remark).strip()
        if final_remark != remark:
            preserved.append(f"пользовательское название '{final_remark}'")

    # Расписание сброса трафика инбаунда
    final_tr = target_tr
    final_tr_day = target_tr_day
    if tr_col:
        cur_tr = None
        cur_tr_day = 1
        try:
            sel_cols = f"{tr_col}, {trd_col}" if trd_col else tr_col
            cur.execute(f"SELECT {sel_cols} FROM inbounds WHERE id = ?", (inbound_id,))
            tr_row = cur.fetchone()
            if tr_row:
                cur_tr = tr_row[0]
                if trd_col and len(tr_row) > 1 and tr_row[1] is not None:
                    cur_tr_day = tr_row[1]
        except Exception:
            pass

        if cur_tr and cur_tr not in ("never", ""):
            final_tr = cur_tr
            final_tr_day = cur_tr_day
            preserved.append(f"расписание сброса трафика '{cur_tr}' (день {cur_tr_day})")
        else:
            final_tr = target_tr
            final_tr_day = target_tr_day
            repairs.append(f"настроен ежемесячный сброс трафика (1-го числа в 00:00)")

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
                    for limit_field in ["totalGB", "expiryTime", "limitIp", "tgId", "reset", "resetDay", "resetMax", "trafficReset", "trafficResetDay", "enable"]:
                        if limit_field in ec:
                            merged_c[limit_field] = ec[limit_field]
                    if "trafficReset" not in merged_c or merged_c.get("trafficReset") in ("", "never", None):
                        merged_c["trafficReset"] = target_tr
                    if "trafficResetDay" not in merged_c or not merged_c.get("trafficResetDay"):
                        merged_c["trafficResetDay"] = target_tr_day
                    if "resetDay" not in merged_c or not merged_c.get("resetDay"):
                        merged_c["resetDay"] = target_tr_day
                    if protocol == "shadowsocks" and ec.get("password"):
                        if not globals().get("regen_server_keys", False) and "validate_ss2022_key" in globals() and validate_ss2022_key(ec["password"], target_settings.get("method", "2022-blake3-aes-256-gcm")):
                            merged_c["password"] = ec["password"]
                        else:
                            merged_c["password"] = globals().get("unified_ss_client_pass") or (generate_ss2022_key(target_settings.get("method", "2022-blake3-aes-256-gcm")) if "generate_ss2022_key" in globals() else ec.get("password"))
                            if globals().get("regen_server_keys", False):
                                repairs.append("обновлен ключ единого клиента SS-2022")
                            else:
                                repairs.append("исправлен невалидный ключ единого клиента SS-2022")
                    elif protocol == "tuic":
                        if ec.get("uuid"): merged_c["uuid"] = ec["uuid"]
                        if ec.get("password"): merged_c["password"] = ec["password"]
                    elif protocol == "mtproto":
                        if ec.get("secret") and not globals().get("regen_server_keys", False):
                            if "validate_mtproto_secret" not in globals() or validate_mtproto_secret(ec["secret"]):
                                merged_c["secret"] = ec["secret"]
                            else:
                                merged_c["secret"] = globals().get("unified_mtp_secret") or (generate_mtproto_secret(globals().get("mtproto_faketls_domain", "gateway.icloud.com")) if "generate_mtproto_secret" in globals() else ec.get("secret"))
                                repairs.append("исправлен невалидный FakeTLS секрет MTProto единого клиента")
                        else:
                            merged_c["secret"] = globals().get("unified_mtp_secret") or (generate_mtproto_secret(globals().get("mtproto_faketls_domain", "gateway.icloud.com")) if "generate_mtproto_secret" in globals() else ec.get("secret"))
                            if globals().get("regen_server_keys", False):
                                repairs.append("обновлен FakeTLS секрет MTProto единого клиента")
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
            for ec in existing_clients:
                if "trafficReset" not in ec or ec.get("trafficReset") in ("", "never", None):
                    ec["trafficReset"] = target_tr
                if "trafficResetDay" not in ec or not ec.get("trafficResetDay"):
                    ec["trafficResetDay"] = target_tr_day
                if "resetDay" not in ec or not ec.get("resetDay"):
                    ec["resetDay"] = target_tr_day
            target_settings["clients"] = existing_clients
            preserved.append(f"клиенты ({len(existing_clients)} польз.)")
        else:
            repairs.append("добавлен клиент по умолчанию")

    # Б. Проверка и ремонт VLESS REALITY
    if protocol == "vless" and "realitySettings" in target_stream:
        cur_reality = cur_stream.get("realitySettings", {})
        
        # Сохранение privateKey
        priv = cur_reality.get("privateKey")
        if priv and not globals().get("regen_server_keys", False):
            target_stream["realitySettings"]["privateKey"] = priv
            preserved.append("privateKey Reality")
        elif priv and globals().get("regen_server_keys", False):
            repairs.append("обновлен серверный privateKey Reality")
        
        # Сохранение shortIds
        sids = cur_reality.get("shortIds")
        if sids and not globals().get("regen_server_keys", False):
            target_stream["realitySettings"]["shortIds"] = sids
            preserved.append("shortIds")
        elif sids and globals().get("regen_server_keys", False):
            repairs.append("обновлен пул shortIds Reality")

        # Ремонт / сохранение settings.publicKey
        pub = cur_reality.get("settings", {}).get("publicKey") or cur_reality.get("publicKey")
        if pub and not globals().get("regen_server_keys", False):
            target_stream["realitySettings"]["settings"]["publicKey"] = pub
            if not cur_reality.get("settings", {}).get("publicKey"):
                repairs.append("исправлен отсутствующий settings.publicKey (устранена ошибка empty password)")
            else:
                preserved.append("publicKey")
        else:
            derived_pub = curve25519_reality_pubkey(target_stream["realitySettings"]["privateKey"])
            if derived_pub:
                target_stream["realitySettings"]["settings"]["publicKey"] = derived_pub
                if globals().get("regen_server_keys", False):
                    repairs.append("обновлен серверный publicKey Reality")
                else:
                    repairs.append("восстановлен settings.publicKey по x25519")

        # settings.fingerprint
        tgt_fp = target_stream.get("realitySettings", {}).get("settings", {}).get("fingerprint")
        cur_fp = cur_reality.get("settings", {}).get("fingerprint")
        if tgt_fp and cur_fp and tgt_fp != cur_fp:
            target_stream["realitySettings"]["settings"]["fingerprint"] = tgt_fp
            repairs.append(f"обновлен fingerprint Reality ({cur_fp} -> {tgt_fp})")
        elif cur_fp and not tgt_fp:
            if "settings" in target_stream["realitySettings"] and isinstance(target_stream["realitySettings"]["settings"], dict):
                target_stream["realitySettings"]["settings"]["fingerprint"] = cur_fp

        # Ремонт мертвого swdist.microsoft.com SNI или пустых значений, либо обновление пула SNI
        old_snis = cur_reality.get("serverNames", [])
        old_dest = str(cur_reality.get("dest", "")).strip()
        target_snis = target_stream["realitySettings"].get("serverNames", [])
        c_sni_fallback = globals().get("classic_sni", "dl.google.com")
        c_port = globals().get("classic_port", 46443)

        if any("swdist.microsoft.com" in s for s in old_snis) or "swdist.microsoft.com" in old_dest:
            chosen_snis = target_snis if (target_snis and not any("swdist.microsoft.com" in s for s in target_snis)) else [c_sni_fallback]
            target_stream["realitySettings"]["serverNames"] = chosen_snis
            target_stream["realitySettings"]["dest"] = f"{chosen_snis[0]}:443"
            target_stream["realitySettings"]["xver"] = 0
            repairs.append(f"заменен мертвый SNI swdist.microsoft.com -> {','.join(chosen_snis)}")
        elif target_snis and target_snis != old_snis:
            target_stream["realitySettings"]["serverNames"] = target_snis
            if port == c_port or tag == "in-classic-reality" or cur_tag == "in-classic-reality":
                target_stream["realitySettings"]["dest"] = f"{target_snis[0]}:443"
                target_stream["realitySettings"]["target"] = f"{target_snis[0]}:443"
                if "settings" in target_stream["realitySettings"] and isinstance(target_stream["realitySettings"]["settings"], dict):
                    target_stream["realitySettings"]["settings"]["serverName"] = target_snis[0]
            repairs.append(f"обновлен пул SNI Reality ({','.join(target_snis)})")
        elif old_snis:
            target_stream["realitySettings"]["serverNames"] = old_snis
            target_stream["realitySettings"]["dest"] = old_dest or target_stream["realitySettings"]["dest"]
            preserved.append(f"SNI ({','.join(old_snis)})")
        elif target_snis:
            target_stream["realitySettings"]["serverNames"] = target_snis

        # Строгая гарантия параметров VLESS REALITY (маскировка под свой сайт: Nginx Fallback + Xver=1 + target)
        s_port = globals().get("steal_port", 45443)
        sc_port = globals().get("steal_compat_port", 47443)
        rf_port = globals().get("reality_fallback_port", 9443)
        if port in (s_port, sc_port) or tag in ("in-steal-reality", "in-steal-backup", "in-steal-compat") or cur_tag in ("in-steal-reality", "in-steal-backup", "in-steal-compat"):
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
        c_sni = globals().get("classic_sni", "dl.google.com")
        if port == c_port or tag == "in-classic-reality" or cur_tag == "in-classic-reality":
            if not target_stream["realitySettings"].get("dest"):
                target_stream["realitySettings"]["dest"] = f"{c_sni}:443"
                repairs.append(f"восстановлен пустой dest -> {c_sni}:443")
            target_stream["realitySettings"]["target"] = target_stream["realitySettings"]["dest"]
            target_stream["realitySettings"]["xver"] = 0

    # В. Проверка и ремонт xHTTP
    if protocol == "vless" and "xhttpSettings" in target_stream:
        cur_xh = cur_stream.get("xhttpSettings", {})
        tgt_p = (target_stream["xhttpSettings"].get("path") or "").strip("/")
        cur_p = (cur_xh.get("path") or "").strip("/")
        if (not tgt_p or tgt_p == "Stream-One-Path" or tgt_p.startswith("vless-")) and cur_p:
            target_stream["xhttpSettings"]["path"] = f"/{cur_p}/"
            preserved.append(f"path (/{cur_p}/)")
        elif cur_p and tgt_p == cur_p:
            preserved.append(f"path (/{cur_p}/)")
        elif cur_p and tgt_p != cur_p:
            repairs.append(f"синхронизирован path xHTTP: /{cur_p}/ -> /{tgt_p}/")
        target_stream["xhttpSettings"]["mode"] = cur_xh.get("mode") or target_stream["xhttpSettings"].get("mode") or "auto"
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
        if cur_srv_pwd and not globals().get("regen_server_keys", False) and "validate_ss2022_key" in globals() and validate_ss2022_key(cur_srv_pwd, ss_method):
            target_settings["password"] = cur_srv_pwd
            preserved.append("серверный ключ SS-2022")
        elif "generate_ss2022_key" in globals():
            target_settings["password"] = target_settings.get("password") or generate_ss2022_key(ss_method)
            if globals().get("regen_server_keys", False):
                repairs.append("обновлен серверный мастер-ключ SS-2022")
            else:
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
    h_port = globals().get("hy2_port", 443)
    expected_ext_port = 443 if protocol in ("vless", "hysteria") and port != h_port else (h_port if protocol == "hysteria" else port)

    cur_domain = globals().get("domain", "")
    def_ext = default_stream.get("externalProxy", [])
    def_dest = def_ext[0].get("dest") if (def_ext and isinstance(def_ext, list) and def_ext[0].get("dest")) else cur_domain
    def_sni = def_ext[0].get("sni", "") if (def_ext and isinstance(def_ext, list) and def_ext[0].get("sni")) else ""

    force_sub_flag = globals().get("force_sub", False)
    # Сохраняем кастомный хост узла (dest), если он был настроен и не равен localhost
    target_dest = def_dest
    if not force_sub_flag and cur_ext and len(cur_ext) > 0 and cur_ext[0].get("dest"):
        ext_dest = str(cur_ext[0]["dest"]).strip()
        if ext_dest and ext_dest not in ("127.0.0.1", "localhost", "0.0.0.0"):
            if ext_dest == cur_domain and def_dest != cur_domain:
                target_dest = def_dest
            else:
                target_dest = ext_dest
                if ext_dest != cur_domain and ext_dest != def_dest:
                    preserved.append(f"кастомный хост узла ({ext_dest})")

    if protocol in ("shadowsocks", "mtproto", "amneziawg"):
        force_tls_val = "none"
    elif protocol == "vless" and "realitySettings" in target_stream:
        force_tls_val = "same"
    else:
        force_tls_val = "tls"

    cur_fps = [ce.get("fingerprint") for ce in cur_ext] if (cur_ext and isinstance(cur_ext, list)) else []
    def_fps = [de.get("fingerprint") for de in def_ext] if (def_ext and isinstance(def_ext, list)) else []
    fp_changed = bool(def_fps and cur_fps != def_fps)
    sni_pool_changed = bool(target_snis and target_snis != old_snis)
    if len(def_ext) > 1 or sni_pool_changed or fp_changed:
        updated_ext = []
        for de in def_ext:
            entry = dict(de)
            if target_dest:
                entry["dest"] = target_dest
            entry["port"] = expected_ext_port
            entry["forceTls"] = force_tls_val
            if "alpn" in entry and isinstance(entry["alpn"], str):
                entry["alpn"] = [entry["alpn"]] if entry["alpn"] else []
            updated_ext.append(entry)
        target_stream["externalProxy"] = updated_ext
        if cur_ext != updated_ext:
            repairs.append(f"обновлен externalProxy ({len(updated_ext)} узлов)")
        else:
            preserved.append(f"externalProxy ({len(updated_ext)} узлов)")
    else:
        # Сохраняем SNI для externalProxy (критично для VLESS REALITY и маршрутизации Nginx Stream L4)
        target_sni = def_sni
        if not force_sub_flag and cur_ext and len(cur_ext) > 0 and cur_ext[0].get("sni"):
            ext_sni = str(cur_ext[0]["sni"]).strip()
            if ext_sni:
                if ext_sni == cur_domain and def_sni != cur_domain:
                    target_sni = def_sni
                else:
                    target_sni = ext_sni
                    if target_sni != def_sni:
                        preserved.append(f"кастомный externalProxy SNI ({ext_sni})")

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
                ext_alpn = def_ext[0]["alpn"]
                if isinstance(ext_alpn, str):
                    ext_alpn = [ext_alpn] if ext_alpn else []
                ext_entry["alpn"] = ext_alpn

        def_fp = def_ext[0].get("fingerprint") if (def_ext and isinstance(def_ext, list) and len(def_ext) > 0) else None
        cur_fp_single = cur_ext[0].get("fingerprint") if (cur_ext and isinstance(cur_ext, list) and len(cur_ext) > 0) else None

        def_alpn = def_ext[0].get("alpn") if (def_ext and isinstance(def_ext, list) and len(def_ext) > 0) else None
        if isinstance(def_alpn, str):
            def_alpn = [def_alpn] if def_alpn else []
        cur_alpn = cur_ext[0].get("alpn") if (cur_ext and isinstance(cur_ext, list) and len(cur_ext) > 0) else None

        alpn_needs_repair = False
        if isinstance(cur_alpn, str):
            alpn_needs_repair = True
        elif def_alpn is not None and cur_alpn != def_alpn:
            alpn_needs_repair = True

        needs_ext_repair = (
            not cur_ext
            or cur_ext[0].get("port") != expected_ext_port
            or cur_ext[0].get("dest") != target_dest
            or cur_ext[0].get("remark") != final_remark
            or cur_ext[0].get("forceTls") != force_tls_val
            or (target_sni and cur_ext[0].get("sni") != target_sni)
            or (def_fp and cur_fp_single != def_fp)
            or alpn_needs_repair
        )

        if needs_ext_repair:
            target_stream["externalProxy"] = [ext_entry]
            sni_desc = f", sni: {target_sni}" if target_sni else ""
            repairs.append(f"исправлен externalProxy -> {target_dest}:{expected_ext_port}{sni_desc}")
        else:
            for ep in cur_ext:
                if isinstance(ep, dict) and "alpn" in ep and isinstance(ep["alpn"], str):
                    ep["alpn"] = [ep["alpn"]] if ep["alpn"] else []
                    repairs.append("исправлен тип alpn в externalProxy (string -> array)")
            target_stream["externalProxy"] = cur_ext
            preserved.append(f"externalProxy :{expected_ext_port}")

    # В 3X-UI externalProxy[].alpn обязан быть массивом (array), строка вызывает ошибку валидации формы
    if "externalProxy" in target_stream and isinstance(target_stream["externalProxy"], list):
        for ep in target_stream["externalProxy"]:
            if isinstance(ep, dict) and "alpn" in ep and isinstance(ep["alpn"], str):
                ep["alpn"] = [ep["alpn"]] if ep["alpn"] else []

    # Синхронизация клиентов в реестре (client_traffics, clients, client_inbounds)
    if "sync_inbound_clients" in globals():
        sync_inbound_clients(inbound_id, protocol, final_remark, target_settings, target_stream)

    # Запись в SQLite
    settings_json = json.dumps(target_settings, ensure_ascii=False)
    stream_json = json.dumps(target_stream, ensure_ascii=False)
    sniffing_json = json.dumps({"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"]})

    if not dry_run:
        update_fields = [
            "protocol = ?", "tag = ?", "remark = ?", "settings = ?",
            "stream_settings = ?", "listen = ?", "sniffing = ?", "enable = ?"
        ]
        effective_enable = (0 if not enabled else cur_enable)
        update_vals = [protocol, tag, final_remark, settings_json, stream_json, listen, sniffing_json, effective_enable]
        if tr_col and tr_col in inb_cols:
            update_fields.append(f"{tr_col} = ?")
            update_vals.append(final_tr)
        if trd_col and trd_col in inb_cols:
            update_fields.append(f"{trd_col} = ?")
            update_vals.append(final_tr_day)
        update_vals.append(inbound_id)
        cur.execute(f"UPDATE inbounds SET {', '.join(update_fields)} WHERE id = ?", tuple(update_vals))

    status_str = f"  [ОБНОВЛЕН] {final_remark} (порт {port}):"
    if repairs:
        status_str += f"\n    -> Исправлено: {', '.join(repairs)}"
    if preserved:
        status_str += f"\n    -> Сохранено: {', '.join(preserved)}"
    print(status_str)
    return inbound_id


# --- Применение эталонных конфигураций инбаундов с единым клиентом ---

# 1. Steal-Oneself REALITY (45443)
if enable_steal:
    s_set = {"clients": [{"id": unified_uuid, "flow": "xtls-rprx-vision", "email": unified_email, "subId": unified_sub_id, "enable": True}], "decryption": "none", "testseed": [900, 500, 900, 256]}
    s_str = {
        "network": "tcp",
        "tcpSettings": {"acceptProxyProtocol": True, "header": {"type": "none"}},
        "security": "reality",
        "realitySettings": {
            "show": False, "xver": 1, "dest": f"127.0.0.1:{reality_fallback_port}", "target": f"127.0.0.1:{reality_fallback_port}",
            "serverNames": [steal_dom], "privateKey": def_reality_priv, "minClientVer": "1.0.0",
            "shortIds": def_reality_sids,
            "settings": {"publicKey": def_reality_pub, "fingerprint": reality_fingerprint, "serverName": steal_dom, "spiderX": "/"}
        },
        "externalProxy": [{"dest": domain, "port": 443, "forceTls": "same", "sni": steal_dom, "fingerprint": reality_fingerprint, "remark": make_remark("VLESS Steal")}]
    }
    steal_remark = make_remark("VLESS Steal")
    steal_ib_id = smart_reconcile_inbound(steal_port, "vless", "in-steal-reality", steal_remark, s_set, s_str, listen="127.0.0.1")

# 1.1 Steal-Oneself REALITY Backup (47443, static.domain, flow: "")
if enable_steal_compat:
    sc_set = {"clients": [{"id": unified_uuid, "flow": "", "email": unified_email, "subId": unified_sub_id, "enable": True}], "decryption": "none", "testseed": [900, 500, 900, 256]}
    sc_str = {
        "network": "tcp",
        "tcpSettings": {"acceptProxyProtocol": True, "header": {"type": "none"}},
        "security": "reality",
        "realitySettings": {
            "show": False, "xver": 1, "dest": f"127.0.0.1:{reality_fallback_port}", "target": f"127.0.0.1:{reality_fallback_port}",
            "serverNames": [steal_compat_dom], "privateKey": def_reality_priv, "minClientVer": "1.0.0",
            "shortIds": def_reality_sids,
            "settings": {"publicKey": def_reality_pub, "fingerprint": reality_fingerprint, "serverName": steal_compat_dom, "spiderX": "/"}
        },
        "externalProxy": [{"dest": domain, "port": 443, "forceTls": "same", "sni": steal_compat_dom, "fingerprint": reality_fingerprint, "remark": make_remark("VLESS Steal Backup")}]
    }
    steal_compat_remark = make_remark("VLESS Steal Backup")
    steal_compat_ib_id = smart_reconcile_inbound(steal_compat_port, "vless", "in-steal-backup", steal_compat_remark, sc_set, sc_str, listen="127.0.0.1")

# 2. Classic REALITY (46443)
if enable_classic:
    c_set = {"clients": [{"id": unified_uuid, "flow": "xtls-rprx-vision", "email": unified_email, "subId": unified_sub_id, "enable": True}], "decryption": "none", "testseed": [900, 500, 900, 256]}
    c_str = {
        "network": "tcp",
        "tcpSettings": {"acceptProxyProtocol": True, "header": {"type": "none"}},
        "security": "reality",
        "realitySettings": {
            "show": False, "xver": 0, "dest": f"{classic_sni}:443", "target": f"{classic_sni}:443",
            "serverNames": classic_snis, "privateKey": def_reality_priv, "minClientVer": "1.0.0",
            "shortIds": def_reality_sids,
            "settings": {"publicKey": def_reality_pub, "fingerprint": reality_fingerprint, "serverName": classic_sni, "spiderX": "/"}
        },
        "externalProxy": [
            {
                "dest": domain,
                "port": 443,
                "forceTls": "same",
                "sni": csni,
                "fingerprint": reality_fingerprint,
                "remark": make_remark(f"VLESS Classic ({csni})" if len(classic_snis) > 1 else "VLESS Classic")
            }
            for csni in classic_snis
        ]
    }
    classic_remark = make_remark("VLESS Classic")
    classic_ib_id = smart_reconcile_inbound(classic_port, "vless", "in-classic-reality", classic_remark, c_set, c_str, listen="127.0.0.1")

# 3. VLESS xHTTP (50443)
if harvested_vless_dekey and harvested_vless_enkey:
    vless_dekey, vless_enkey = harvested_vless_dekey, harvested_vless_enkey
else:
    vless_dekey, vless_enkey = generate_vlessenc_keypair()

xhttp_client = {"id": unified_uuid, "flow": "", "email": unified_email, "subId": unified_sub_id, "enable": True}
if vless_dekey and vless_enkey:
    xhttp_client["encryption"] = vless_enkey
    x_set = {"clients": [xhttp_client], "decryption": vless_dekey, "encryption": vless_enkey}
else:
    x_set = {"clients": [xhttp_client], "decryption": "none"}
vless_target_dom = (os.environ.get("VLESS_DOMAIN") or os.environ.get("SUB_DOMAIN") or domain).strip()
xhttp_listen = "0.0.0.0" if is_docker_env else "127.0.0.1"
x_str = {
    "network": "xhttp",
    "xhttpSettings": {
        "path": f"/{xhttp_path.strip('/')}/", "host": vless_target_dom, "mode": "auto",
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
    "externalProxy": [{"dest": vless_target_dom, "port": 443, "forceTls": "tls", "sni": vless_target_dom, "fingerprint": reality_fingerprint, "alpn": ["h2"], "remark": make_remark("VLESS xHTTP")}]
}
xhttp_remark = make_remark("VLESS xHTTP")
xhttp_ib_id = smart_reconcile_inbound(xhttp_port, "vless", "in-xhttp-stream", xhttp_remark, x_set, x_str, listen=xhttp_listen)

unified_vless_enkey = ""
cur.execute("SELECT settings FROM inbounds WHERE id = ? OR port = ?", (xhttp_ib_id, xhttp_port))
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
    unified_vless_enkey = vless_enkey or ""

# 4. Hysteria 2 (443)
if enable_hy2:
    hy2_has_cert = False
    _db_d = os.path.dirname(os.path.abspath(db_path)) if "db_path" in globals() else "/etc/x-ui"
    _h_c = os.path.join(_db_d, "server.crt")
    _h_k = os.path.join(_db_d, "server.key")
    if os.path.isfile(hy2_cert) and os.path.isfile(hy2_key):
        hy2_has_cert = True
    elif (os.path.isfile(_h_c) and os.path.isfile(_h_k)) or (os.path.isfile("/etc/x-ui/server.crt") and os.path.isfile("/etc/x-ui/server.key")):
        hy2_cert = "/etc/x-ui/server.crt"
        hy2_key = "/etc/x-ui/server.key"
        hy2_has_cert = True
    elif hy2_cert.startswith("/etc/x-ui/") and os.path.isfile(_h_c) and os.path.isfile(_h_k):
        hy2_has_cert = True

    h_set = {"clients": [{"id": unified_hy2_pass, "auth": unified_hy2_pass, "password": unified_hy2_pass, "email": unified_email, "subId": unified_sub_id, "enable": True}], "version": 2}
    h_str = {
        "network": "hysteria",
        "hysteriaSettings": {"version": 2, "udpIdleTimeout": 60, "masquerade": {"type": "proxy", "url": "http://127.0.0.1:80"}},
        "security": "tls",
        "tlsSettings": {
            "serverName": hy2_domain, "minVersion": "1.3", "maxVersion": "1.3",
            "certificates": [{"certificateFile": hy2_cert, "keyFile": hy2_key}], "alpn": ["h3"]
        },
        "externalProxy": [{"dest": hy2_domain, "port": hy2_port, "forceTls": "tls", "remark": make_remark("Hysteria 2")}]
    }
    hy2_remark = make_remark("Hysteria 2")
    if not hy2_has_cert:
        print(f"  [ПРЕДУПРЕЖДЕНИЕ] SSL-сертификат для Hysteria 2 ({hy2_cert}) не найден на диске.")
        print(f"  Инбаунд Hysteria 2 создан в отключенном состоянии (enable: 0) во избежание сбоя Xray-core.")
    smart_reconcile_inbound(hy2_port, "hysteria", "in-hysteria2", hy2_remark, h_set, h_str, listen="0.0.0.0", enabled=hy2_has_cert)

# 5. AmneziaWG v3.1 (8443)
if enable_awg_v3:
    awg_i1_env = os.environ.get("AWG_I1", "").strip()
    if awg_i1_env.lower() == "dns":
        awg_i1_env = "<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>"
    a3_set = {
        "clients": [{
            "privateKey": def_wg_c_priv, "publicKey": def_wg_c_pub,
            "allowedIPs": ["10.8.1.2/32"], "email": unified_email, "subId": unified_sub_id, "enable": True,
            "keepAlive": "15-25"
        }],
        "server": {
            "h1": "1", "h2": "2", "h3": "3", "h4": "4",
            "jc": 4, "jmin": 40, "jmax": 70,
            "s1": 16, "s2": 16, "s3": 16, "s4": 16,
            "mtu": 1280,
            "primaryDns": awg_primary_dns, "secondaryDns": awg_secondary_dns,
            "privateKey": def_wg_s_priv, "publicKey": def_wg_s_pub,
            "headerProtectionKey": unified_awg_hpk,
            "randomTrailers": True,
            "disableCookies": False,
            "keepaliveTimeout": "15-20",
            "rekeyAfterTime": "120-170",
            "rekeyTimeout": "3-4",
            "rejectAfterTime": "180-210",
            "maxHandshakeAttempts": "20-25",
            "subnetCidr": awg_subnet_cidr, "subnetIp": awg_subnet_ip,
            "i1": awg_i1_env
        }
    }
    a3_str = {"externalProxy": [{"dest": domain, "port": awg_v3_port, "remark": make_remark("AmneziaWG v3")}]}
    awg_v3_remark = make_remark("AmneziaWG v3")
    smart_reconcile_inbound(awg_v3_port, "amneziawg", "in-8443-udp", awg_v3_remark, a3_set, a3_str, listen="0.0.0.0")

# 6. AmneziaWG v2.0 (8444)
if enable_awg_v2:
    a2_set = {
        "clients": [{
            "privateKey": def_wg_c_priv, "publicKey": def_wg_c_pub,
            "allowedIPs": ["10.8.2.2/32"], "email": unified_email, "subId": unified_sub_id, "enable": True,
            "keepAlive": "15-25"
        }],
        "server": {
            "h1": "149419586", "h2": "878791997", "h3": "1251051976", "h4": "1657628296",
            "jc": 2, "jmin": 20, "jmax": 50, "mtu": 1280,
            "primaryDns": awg_primary_dns, "secondaryDns": awg_secondary_dns,
            "privateKey": def_wg_s_priv, "publicKey": def_wg_s_pub,
            "s1": 16, "s2": 20, "s3": 24, "s4": 16,
            "subnetCidr": 24, "subnetIp": "10.8.2.0"
        }
    }
    a2_str = {"externalProxy": [{"dest": domain, "port": awg_v2_port, "remark": make_remark("AmneziaWG v2")}]}
    awg_v2_remark = make_remark("AmneziaWG v2")
    smart_reconcile_inbound(awg_v2_port, "amneziawg", "in-awg-v2", awg_v2_remark, a2_set, a2_str, listen="0.0.0.0")

# 7. Shadowsocks 2022 (8388)
if enable_ss2022:
    ss_set = {
        "method": ss_method,
        "password": unified_ss_server_pass,
        "network": "tcp,udp",
        "udpOverTcp": True,
        "udp_over_tcp": True,
        "clients": [{
            "email": unified_email,
            "password": unified_ss_client_pass,
            "subId": unified_sub_id,
            "enable": True
        }]
    }
    ss_ext_proxies = [{"dest": domain, "port": ss2022_port, "forceTls": "none", "remark": make_remark("Shadowsocks 2022")}]
    if enable_shadowtls:
        ss_ext_proxies.append({"dest": domain, "port": shadowtls_port, "forceTls": "tls", "remark": make_remark("ShadowTLS v4 + SS-2022")})
    ss_str = {
        "network": "tcp",
        "security": "none",
        "externalProxy": ss_ext_proxies
    }
    ss_remark = make_remark("Shadowsocks 2022")
    smart_reconcile_inbound(ss2022_port, "shadowsocks", "in-shadowsocks-2022", ss_remark, ss_set, ss_str, listen="0.0.0.0")

# 8. TUIC v5 (8448)
if enable_tuic:
    tuic_set = {
        "certificate": tuic_cert,
        "private_key": tuic_key,
        "congestion_control": "bbr",
        "alpn": ["h3", "spdy/3.1"],
        "udp_relay_mode": "native",
        "zero_rtt_handshake": False,
        "max_idle_time": 15,
        "authentication_timeout": 3,
        "max_udp_relay_packet_size": 1500,
        "sni": domain,
        "clients": [{
            "uuid": unified_tuic_uuid,
            "password": unified_tuic_pass,
            "email": unified_email,
            "subId": unified_sub_id,
            "enable": True
        }]
    }
    tuic_str = {
        "network": "quic",
        "security": "tls",
        "externalProxy": [{"dest": domain, "port": tuic_port, "forceTls": "tls", "remark": make_remark("TUIC v5")}]
    }
    tuic_remark = make_remark("TUIC v5")
    smart_reconcile_inbound(tuic_port, "tuic", "in-tuic-v5", tuic_remark, tuic_set, tuic_str, listen="0.0.0.0")

# 9. Telegram MTProxy FakeTLS (8444)
if enable_mtproto:
    mtp_set = {
        "preferIp": "prefer-ipv4",
        "domainFronting": {
            "ip": mtproto_faketls_domain,
            "port": 443,
            "proxyProtocol": False
        },
        "clients": [{
            "email": unified_email,
            "secret": unified_mtp_secret,
            "adTag": unified_mtp_adtag,
            "subId": unified_sub_id,
            "enable": True
        }]
    }
    mtp_str = {
        "network": "tcp",
        "security": "none",
        "externalProxy": [{"dest": domain, "port": mtproto_port, "forceTls": "none", "remark": make_remark("Telegram MTProxy")}]
    }
    mtp_remark = make_remark("Telegram MTProxy")
    smart_reconcile_inbound(mtproto_port, "mtproto", "in-mtproto-faketls", mtp_remark, mtp_set, mtp_str, listen="0.0.0.0")

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
        exclude_from_sub_types TEXT DEFAULT '',
        shuffle_host INTEGER DEFAULT 0,
        mihomo_x25519 INTEGER DEFAULT 0
    )
""")
cur.execute("PRAGMA table_info(hosts)")
active_host_cols = {r[1] for r in cur.fetchall()}
if "shuffle_host" not in active_host_cols and "shuffleHost" not in active_host_cols:
    try:
        cur.execute("ALTER TABLE hosts ADD COLUMN shuffle_host INTEGER DEFAULT 0")
        active_host_cols.add("shuffle_host")
    except Exception:
        pass
if "mihomo_x25519" not in active_host_cols and "mihomoX25519" not in active_host_cols:
    try:
        cur.execute("ALTER TABLE hosts ADD COLUMN mihomo_x25519 INTEGER DEFAULT 0")
        active_host_cols.add("mihomo_x25519")
    except Exception:
        pass

inbound_col = "inboundId" if "inboundId" in active_host_cols else "inbound_id"
sort_col = "sortOrder" if "sortOrder" in active_host_cols else "sort_order"
shuffle_col = "shuffleHost" if "shuffleHost" in active_host_cols else "shuffle_host"
mihomo_col = "mihomoX25519" if "mihomoX25519" in active_host_cols else "mihomo_x25519"

def insert_host_entry(ib_id, host_remark, addr, host_port, sec, host_sni="", host_path="", host_alpn="", host_fp="firefox", sort_order=0, shuffle_host=0, mihomo_x25519=0):
    if ib_id is None or dry_run:
        return
    gid = str(uuid.uuid4())
    col_candidates = {
        "group_id": gid, "groupId": gid,
        "inbound_id": ib_id, "inboundId": ib_id,
        "sort_order": sort_order, "sortOrder": sort_order,
        "remark": host_remark, "address": addr, "port": host_port, "security": sec,
        "sni": host_sni, "host_header": host_sni or addr, "hostHeader": host_sni or addr, "path": host_path,
        "alpn": host_alpn, "fingerprint": host_fp, "allow_insecure": 0, "allowInsecure": 0,
        "is_disabled": 0, "isDisabled": 0, "is_hidden": 0, "isHidden": 0,
        "tags": "", "ech_config_list": "", "mux_params": "", "sockopt_params": "",
        "final_mask": "", "exclude_from_sub_types": "",
        "shuffle_host": shuffle_host, "shuffleHost": shuffle_host,
        "mihomo_x25519": mihomo_x25519, "mihomoX25519": mihomo_x25519
    }
    insert_data = {k: v for k, v in col_candidates.items() if k in active_host_cols}
    keys = list(insert_data.keys())
    vals = [insert_data[k] for k in keys]
    placeholders = ",".join(["?"] * len(keys))
    cur.execute(f"INSERT INTO hosts ({','.join(keys)}) VALUES ({placeholders})", vals)

def sync_host_entry(ib_id, host_remark, addr, host_port, sec, host_sni="", host_path="", host_alpn="", host_fp="firefox", sort_order=0, shuffle_host=0, mihomo_x25519=0):
    if ib_id is None:
        return
    cur.execute(f"SELECT id, remark FROM hosts WHERE {inbound_col} = ?", (ib_id,))
    h_row = cur.fetchone()
    if h_row:
        h_id, existing_rem = h_row
        final_h_remark = existing_rem if (existing_rem and existing_rem.strip()) else host_remark
        if not dry_run:
            update_fields = [
                "address = ?", "port = ?", "security = ?", "sni = ?",
                "path = ?", "alpn = ?", "fingerprint = ?", f"{sort_col} = ?", "remark = ?"
            ]
            update_vals = [addr, host_port, sec, host_sni, host_path, host_alpn, host_fp, sort_order, final_h_remark]
            if shuffle_col in active_host_cols:
                update_fields.append(f"{shuffle_col} = ?")
                update_vals.append(shuffle_host)
            if mihomo_col in active_host_cols:
                update_fields.append(f"{mihomo_col} = ?")
                update_vals.append(mihomo_x25519)
            update_vals.append(h_id)
            cur.execute(f"UPDATE hosts SET {', '.join(update_fields)} WHERE id = ?", tuple(update_vals))
    else:
        insert_host_entry(ib_id, host_remark, addr, host_port, sec, host_sni=host_sni, host_path=host_path, host_alpn=host_alpn, host_fp=host_fp, sort_order=sort_order, shuffle_host=shuffle_host, mihomo_x25519=mihomo_x25519)

def lookup_inbound_id(tag_val, port_val):
    cur.execute("SELECT id FROM inbounds WHERE tag = ? OR port = ?", (tag_val, port_val))
    r = cur.fetchone()
    return r[0] if r else None

reality_fp = globals().get("reality_fingerprint", "firefox")
if enable_steal:
    s_iid = steal_ib_id if ('steal_ib_id' in locals() and steal_ib_id) else lookup_inbound_id("in-steal-reality", steal_port)
    if s_iid:
        cur.execute("SELECT remark FROM inbounds WHERE id = ?", (s_iid,))
        r_rem = cur.fetchone()
        s_rem = r_rem[0] if r_rem and r_rem[0] else steal_remark
        sync_host_entry(s_iid, s_rem, domain, 443, "same", host_sni=steal_dom, host_fp=reality_fp, sort_order=1, mihomo_x25519=1)

if globals().get("enable_steal_compat", False) or ('enable_steal_compat' in locals() and enable_steal_compat):
    sc_iid = steal_compat_ib_id if ('steal_compat_ib_id' in locals() and steal_compat_ib_id) else (lookup_inbound_id("in-steal-backup", steal_compat_port) or lookup_inbound_id("in-steal-compat", steal_compat_port))
    if sc_iid:
        cur.execute("SELECT remark FROM inbounds WHERE id = ?", (sc_iid,))
        r_rem = cur.fetchone()
        sc_rem = r_rem[0] if r_rem and r_rem[0] else steal_compat_remark
        sync_host_entry(sc_iid, sc_rem, domain, 443, "same", host_sni=steal_compat_dom, host_fp=reality_fp, sort_order=1, mihomo_x25519=1)

if enable_classic:
    c_iid = classic_ib_id if ('classic_ib_id' in locals() and classic_ib_id) else lookup_inbound_id("in-classic-reality", classic_port)
    if c_iid:
        cur.execute("SELECT remark FROM inbounds WHERE id = ?", (c_iid,))
        r_rem = cur.fetchone()
        c_rem = r_rem[0] if r_rem and r_rem[0] else classic_remark
        if not dry_run:
            cur.execute(f"DELETE FROM hosts WHERE {inbound_col} = ?", (c_iid,))
        for idx, csni in enumerate(classic_snis, start=1):
            h_remark = f"{c_rem} ({csni})" if len(classic_snis) > 1 else c_rem
            insert_host_entry(c_iid, h_remark, domain, 443, "same", host_sni=csni, host_fp=reality_fp, sort_order=idx, shuffle_host=1, mihomo_x25519=1)

x_iid = xhttp_ib_id if ('xhttp_ib_id' in locals() and xhttp_ib_id) else lookup_inbound_id("in-xhttp-stream", xhttp_port)
if x_iid:
    cur.execute("SELECT remark FROM inbounds WHERE id = ?", (x_iid,))
    r_rem = cur.fetchone()
    x_rem = r_rem[0] if r_rem and r_rem[0] else xhttp_remark
    if not dry_run:
        cur.execute(f"DELETE FROM hosts WHERE {inbound_col} = ?", (x_iid,))
    insert_host_entry(x_iid, x_rem, vless_target_dom, 443, "tls", host_sni=vless_target_dom, host_path=f"/{xhttp_path.strip('/')}/", host_alpn=json.dumps(["h2"]), host_fp=reality_fp, sort_order=2)


# Формирование клиентских ссылок для новых протоколов
# SIP002 Base64: ss://BASE64(method:server_psk:user_psk)@host:port#name (совместим с Happ, Shadowrocket, v2rayNG)
raw_ss_userinfo = f"{ss_method}:{unified_ss_server_pass}:{unified_ss_client_pass}"
b64_ss_userinfo = base64.urlsafe_b64encode(raw_ss_userinfo.encode("utf-8")).decode("utf-8").rstrip("=")
ss2022_uri = f"ss://{b64_ss_userinfo}@{domain}:{ss2022_port}#{urllib.parse.quote(make_remark('Shadowsocks 2022'))}"
tuic_uri = f"tuic://{unified_tuic_uuid}:{unified_tuic_pass}@{domain}:{tuic_port}?congestion_control=bbr&alpn=h3&udp_relay_mode=native&sni={domain}#{urllib.parse.quote(make_remark('TUIC v5'))}"
mtproto_tg_uri = f"tg://proxy?server={domain}&port={mtproto_port}&secret={unified_mtp_secret}"
mtproto_https_uri = f"https://t.me/proxy?server={domain}&port={mtproto_port}&secret={unified_mtp_secret}"
mtproto_bot_secret = unified_mtp_secret[2:34] if len(unified_mtp_secret) >= 34 else unified_mtp_secret

# Формирование клиентских реквизитов для протоколов нового поколения (Next-Gen Protocols)
enable_masque = os.environ.get("ENABLE_MASQUE", "n").lower() in ("1", "y", "true")
masque_port = int(os.environ.get("MASQUE_PORT") or "8449")
masque_user = (os.environ.get("MASQUE_USER") or "client").strip()
masque_password = os.environ.get("MASQUE_PASSWORD", "").strip() or unified_ss_client_pass
masque_uri = f"masque://{masque_user}:{masque_password}@{domain}:{masque_port}?alpn=h3#{urllib.parse.quote(make_remark('MASQUE RFC 9484'))}"

enable_shadowtls = os.environ.get("ENABLE_SHADOWTLS", "n").lower() in ("1", "y", "true")
shadowtls_port = int(os.environ.get("SHADOWTLS_PORT") or "8543")
shadowtls_sni = (os.environ.get("SHADOWTLS_SNI") or "gateway.icloud.com").strip()
shadowtls_password = os.environ.get("SHADOWTLS_PASSWORD", "").strip()
shadowtls_uri = f"shadowtls://{shadowtls_password}@{domain}:443?sni={shadowtls_sni}&version=4#{urllib.parse.quote(make_remark('ShadowTLS v4'))}"
ss_shadowtls_uri = f"ss://{b64_ss_userinfo}@{domain}:443?plugin=shadow-tls;host={shadowtls_sni};password={shadowtls_password};version=4#{urllib.parse.quote(make_remark('ShadowTLS + SS-2022'))}"

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
naive_uri = f"naive+https://{naive_user}:{naive_pass}@{naive_domain}:443#{urllib.parse.quote(make_remark('NaïveProxy'))}"

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
        _raw_priv_hex, dnstt_pubkey = generate_dnstt_keypair()
        os.makedirs("/etc/dnstt", exist_ok=True)
        with open("/etc/dnstt/server.key", "w") as kf:
            kf.write(_raw_priv_hex + "\n")
        with open("/etc/dnstt/server.pub", "w") as pf:
            pf.write(dnstt_pubkey + "\n")
        os.chmod("/etc/dnstt/server.key", 0o600)
        os.chmod("/etc/dnstt/server.pub", 0o600)
    except Exception:
        pass
dnstt_cli = f"dnstt-client -doh https://dns.google/dns-query -pubkey {dnstt_pubkey} {dnstt_domain} 127.0.0.1:1080"

if enable_mieru and mieru_user and mieru_pass:
    client_m_port = int(mieru_port.split("-")[0].split(":")[0]) if "-" not in mieru_port and ":" not in mieru_port else mieru_port
    m_protocols = ["UDP"] if mieru_transport == "UDP" else (["TCP"] if mieru_transport == "TCP" else ["TCP", "UDP"])
    m_client_bindings = []
    for p in m_protocols:
        if isinstance(client_m_port, int) or ("-" not in str(client_m_port)):
            m_client_bindings.append({"port": int(str(client_m_port).split("-")[0].split(":")[0]), "protocol": p})
        else:
            m_client_bindings.append({"portRange": str(client_m_port), "protocol": p})

    mieru_client_config = {
        "profiles": [{
            "profileName": "default",
            "user": {
                "name": mieru_user,
                "password": mieru_pass
            },
            "servers": [{
                "ipAddress": domain,
                "portBindings": m_client_bindings
            }],
            "handshakeMode": "HANDSHAKE_STANDARD"
        }],
        "activeProfile": "default",
        "rpcPort": 0,
        "socks5Port": 1080,
        "loggingLevel": "INFO",
        "httpProxyPort": 8080
    }
    if not dry_run:
        try:
            with open("/root/mieru-client.json", "w", encoding="utf-8") as mcf:
                json.dump(mieru_client_config, mcf, indent=2)
            os.chmod("/root/mieru-client.json", 0o600)
        except Exception:
            pass

if not dry_run:
    try:
        cur.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    except Exception:
        pass
    conn.commit()

    # Сохранение параметров единого клиента во временный файл в /run (tmpfs) с безопасными правами
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
            if enable_ss2022:
                f.write(f"SS2022_URI='{ss2022_uri}'\n")
                f.write(f"SS2022_PORT='{ss2022_port}'\n")
            if enable_tuic:
                f.write(f"TUIC_URI='{tuic_uri}'\n")
                f.write(f"TUIC_PORT='{tuic_port}'\n")
            if enable_mtproto:
                f.write(f"MTPROTO_TG_URI='{mtproto_tg_uri}'\n")
                f.write(f"MTPROTO_HTTPS_URI='{mtproto_https_uri}'\n")
                f.write(f"MTPROTO_SECRET='{unified_mtp_secret}'\n")
                f.write(f"MTPROTO_BOT_SECRET='{mtproto_bot_secret}'\n")
                f.write(f"MTPROTO_PORT='{mtproto_port}'\n")
            if enable_masque or os.path.exists("/etc/sing-box/masque.json"):
                f.write(f"MASQUE_URI='{masque_uri}'\n")
                f.write(f"MASQUE_PORT='{masque_port}'\n")
                f.write(f"MASQUE_USER='{masque_user}'\n")
                f.write(f"MASQUE_PASSWORD='{masque_password}'\n")
            if enable_shadowtls or os.path.exists("/etc/systemd/system/shadow-tls.service"):
                f.write(f"SHADOWTLS_URI='{shadowtls_uri}'\n")
                f.write(f"SS_SHADOWTLS_URI='{ss_shadowtls_uri}'\n")
                f.write(f"SHADOWTLS_PORT='{shadowtls_port}'\n")
                f.write(f"SHADOWTLS_SNI='{shadowtls_sni}'\n")
                f.write(f"SHADOWTLS_PASSWORD='{shadowtls_password}'\n")
            if (enable_wstunnel or os.path.exists("/etc/systemd/system/wstunnel.service")) and wstunnel_prefix:
                f.write(f"WSTUNNEL_CLI='{wstunnel_cli}'\n")
                f.write(f"WSTUNNEL_URI='{wstunnel_uri}'\n")
                f.write(f"WSTUNNEL_PREFIX='{wstunnel_prefix}'\n")
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
                f.write(f"MIERU_PORT_MODE={shlex.quote(mieru_port_mode)}\n")
                f.write(f"MIERU_TRANSPORT={shlex.quote(mieru_transport)}\n")
                f.write(f"MIERU_USER={shlex.quote(mieru_user)}\n")
                f.write(f"MIERU_PASS={shlex.quote(mieru_pass)}\n")
                if 'mieru_node_name' in locals():
                    f.write(f"MIERU_NODE_NAME={shlex.quote(mieru_node_name)}\n")
        os.umask(old_umask)
        os.chmod(run_file, 0o600)
    except Exception:
        pass

# Автоматическая генерация / обновление маршрутов Dokploy Traefik Dynamic Configuration
if not dry_run and (is_docker_env or os.path.isdir("/etc/dokploy/traefik/dynamic") or os.path.isdir("/etc/dokploy")):
    try:
        dokploy_dyn_dir = Path("/etc/dokploy/traefik/dynamic")
        dokploy_dyn_dir.mkdir(parents=True, exist_ok=True)
        # Определение имени контейнера backend для Traefik
        backend_name = "3x-ui-dokploy"
        try:
            import subprocess
            _ps_res = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True, timeout=5)
            if _ps_res.returncode == 0:
                for _n in _ps_res.stdout.splitlines():
                    _n = _n.strip()
                    if "3x-ui" in _n or "x-ui" in _n:
                        backend_name = _n
                        break
        except Exception:
            pass

        if backend_name == "3x-ui-dokploy" and dokploy_dyn_dir.is_dir():
            for _yf in dokploy_dyn_dir.glob("*.y*ml"):
                if _yf.name in ("vpn.yml", "dokploy.yml", "middlewares.yml"):
                    continue
                try:
                    _txt = _yf.read_text(encoding="utf-8", errors="ignore")
                    _m = re.search(r'url:\s*["\']?(?:https?|h2c)://([^:/ \'"\n]+)(?::(?:2053|2096|10443|55443|50443|\d+))?', _txt)
                    if _m:
                        _c = _m.group(1).strip()
                        if _c and _c not in ("127.0.0.1", "localhost", "0.0.0.0", "dokploy", "traefik"):
                            backend_name = _c
                            break
                except Exception:
                    pass

        _p_host = (os.environ.get("PANEL_DOMAIN") or f"panel.{domain}").strip()
        _s_host = (os.environ.get("SUB_DOMAIN") or f"sub.{domain}").strip()
        _v_host = vless_target_dom

        _vpn_yml_path = dokploy_dyn_dir / "vpn.yml"
        _vpn_lines = [
            "# ==============================================================================",
            "# DOKPLOY TRAEFIK DYNAMIC CONFIGURATION FOR 3X-UI & VPN SERVICES",
            "# Automatically managed by Smart Reconcile Engine",
            "# ==============================================================================",
            "http:",
            "  routers:",
            "    xui-panel:",
            f"      rule: \"Host(`{_p_host}`)\"",
            "      entryPoints:",
            "        - \"websecure\"",
            "      service: \"xui-panel-service\"",
            "      tls:",
            "        certResolver: \"letsencrypt\"",
            "",
            "    xui-sub:",
            f"      rule: \"Host(`{_s_host}`)\"",
            "      entryPoints:",
            "        - \"websecure\"",
            "      service: \"xui-sub-service\"",
            "      tls:",
            "        certResolver: \"letsencrypt\"",
            "",
            "    xray-xhttp:",
            f"      rule: \"Host(`{_v_host}`)\"",
            "      entryPoints:",
            "        - \"websecure\"",
            "      priority: 1000",
            "      service: \"xray-xhttp-service\"",
            "      tls:",
            "        certResolver: \"letsencrypt\"",
            "",
            "  services:",
            "    xui-panel-service:",
            "      loadBalancer:",
            "        servers:",
            f"          - url: \"http://{backend_name}:{panel_port}\"",
            "",
            "    xui-sub-service:",
            "      loadBalancer:",
            "        servers:",
            f"          - url: \"http://{backend_name}:{sub_port}\"",
            "",
            "    xray-xhttp-service:",
            "      loadBalancer:",
            "        servers:",
            f"          - url: \"h2c://{backend_name}:{xhttp_port}\"",
        ]
        if enable_steal or enable_classic:
            _vpn_lines.extend([
                "",
                "tcp:",
                "  routers:",
            ])
            if enable_steal:
                _vpn_lines.extend([
                    "    reality-steal:",
                    "      entryPoints:",
                    "        - \"websecure\"",
                    f"      rule: \"HostSNI(`reality.{domain}`)\"",
                    "      service: \"reality-steal-service\"",
                    "      tls:",
                    "        passthrough: true",
                    "",
                ])
            if enable_classic:
                _classic_snis = ["www.uni-frankfurt.de", "www.sap.com", "download.videolan.org", "www.siemens.com", "mirror.leaseweb.com"]
                if _parsed_snis:
                    for _ps in _parsed_snis:
                        if _ps not in _classic_snis:
                            _classic_snis.append(_ps)
                _sni_cond = " || ".join([f"HostSNI(`{_s}`)" for _s in _classic_snis])
                _vpn_lines.extend([
                    "    reality-classic:",
                    "      entryPoints:",
                    "        - \"websecure\"",
                    f"      rule: \"{_sni_cond}\"",
                    "      service: \"reality-classic-service\"",
                    "      tls:",
                    "        passthrough: true",
                    "",
                ])
            _vpn_lines.extend([
                "  services:",
            ])
            if enable_steal:
                _vpn_lines.extend([
                    "    reality-steal-service:",
                    "      loadBalancer:",
                    "        servers:",
                    f"          - address: \"{backend_name}:{steal_port}\"",
                    "",
                ])
            if enable_classic:
                _vpn_lines.extend([
                    "    reality-classic-service:",
                    "      loadBalancer:",
                    "        servers:",
                    f"          - address: \"{backend_name}:{classic_port}\"",
                    "",
                ])
        _vpn_yml_path.write_text("\n".join(_vpn_lines) + "\n", encoding="utf-8")
        print(f"  [OK] Маршруты Dokploy Traefik dynamic применены ({backend_name}:{xhttp_port} -> {_v_host}): {_vpn_yml_path}")
    except Exception as _e_dok:
        pass

conn.close()
EOF_PYTHON_CONFIG

    # Нормализация прав доступа и перезапуск служб (Hardened: chmod 600 для защиты от локальной утечки)
    if [ "$DRY_RUN" -eq 0 ]; then
        chmod 600 "$DB_PATH" 2>/dev/null || true

        # Обнаружение исполняемого файла CLI 3X-UI
        XUI_BIN=""
        for candidate in "/usr/local/x-ui/x-ui" "/usr/bin/x-ui" "/usr/local/bin/x-ui"; do
            if [ -x "$candidate" ]; then
                XUI_BIN="$candidate"
                break
            fi
        done
        if [ -z "$XUI_BIN" ] && command -v x-ui >/dev/null 2>&1; then
            XUI_BIN="$(command -v x-ui)"
        fi

        # Синхронизация учетных данных администратора через нативный CLI 3X-UI (bcrypt + сброс login_epoch)
        if [ -n "${ADMIN_USERNAME:-}" ] || [ -n "${ADMIN_PASSWORD:-}" ]; then
            if [ -n "$XUI_BIN" ]; then
                xui_user_args=()
                [ -n "${ADMIN_USERNAME:-}" ] && xui_user_args+=("-username" "$ADMIN_USERNAME")
                [ -n "${ADMIN_PASSWORD:-}" ] && xui_user_args+=("-password" "$ADMIN_PASSWORD")
                log "Синхронизация учетных данных администратора через '$XUI_BIN setting' (bcrypt)..."
                if "$XUI_BIN" setting "${xui_user_args[@]}" >/tmp/xui_setting.log 2>&1; then
                    ok "Учетные данные администратора успешно синхронизированы в 3X-UI (bcrypt)!"
                else
                    warn "Предупреждение при вызове '$XUI_BIN setting': $(cat /tmp/xui_setting.log 2>/dev/null)"
                fi
            fi
        fi

        ensure_node_token

        # Очистка устаревших/невалидных geosite меток в bin/config.json с помощью безопасного JSON парсера
        for cfg_candidate in "/usr/local/x-ui/bin/config.json" "/etc/x-ui/bin/config.json"; do
            if [ -f "$cfg_candidate" ]; then
                "$PYTHON_CMD" - "$cfg_candidate" << 'EOF_CLEAN_JSON' 2>/dev/null || true
import json, sys
cfg_path = sys.argv[1]
try:
    with open(cfg_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    bad_prefixes = ("geosite:ru", "geosite:yandex", "geosite:vk", "geosite:youtube",
                    "geosite:openai", "geosite:google-gemini", "geosite:anthropic", "geosite:cloudflare")
    def clean_obj(obj):
        if isinstance(obj, dict):
            return {k: clean_obj(v) for k, v in obj.items()}
        elif isinstance(obj, list):
            return [clean_obj(x) for x in obj if not (isinstance(x, str) and any(x.startswith(b) for b in bad_prefixes))]
        return obj
    cleaned = clean_obj(data)
    with open(cfg_path, 'w', encoding='utf-8') as f:
        json.dump(cleaned, f, indent=2, ensure_ascii=False)
except Exception:
    pass
EOF_CLEAN_JSON
            fi
        done

        # Обновление ядра Xray-core до последней актуальной версии (v26.10.21+)
        INSTALLED_XRAY_VER=""
        if [[ "${UPDATE_XRAY_CORE:-y}" =~ ^[Yy1] ]]; then
            XRAY_BIN_DIR="/usr/local/x-ui/bin"
            [ -d "$XRAY_BIN_DIR" ] || XRAY_BIN_DIR="/etc/x-ui/bin"
            
            ARCH=$(uname -m 2>/dev/null || echo "x86_64")
            case "$ARCH" in
                x86_64|amd64)   XRAY_ARCH="64"; BIN_NAME="xray-linux-amd64" ;;
                aarch64|arm64)  XRAY_ARCH="arm64-v8a"; BIN_NAME="xray-linux-arm64-v8a" ;;
                armv7*|armhf)   XRAY_ARCH="arm32-v7a"; BIN_NAME="xray-linux-arm32-v7a" ;;
                *)              XRAY_ARCH="64"; BIN_NAME="xray-linux-amd64" ;;
            esac
            
            TARGET_BIN="$XRAY_BIN_DIR/$BIN_NAME"
            [ -f "$TARGET_BIN" ] || TARGET_BIN="$XRAY_BIN_DIR/xray"
            
            CURRENT_VER=""
            if [ -x "$TARGET_BIN" ]; then
                CURRENT_VER=$("$TARGET_BIN" -version 2>/dev/null | { head -n 1 || true; } | { awk '{print $2}' || true; }) || CURRENT_VER=""
            fi

            LATEST_TAG=""
            if command -v curl >/dev/null 2>&1; then
                gh_resp=$(curl -fsSL --connect-timeout 5 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null || true)
                if [ -n "$gh_resp" ]; then
                    if command -v python3 >/dev/null 2>&1; then
                        LATEST_TAG=$(python3 -c 'import json, sys; print(json.loads(sys.stdin.read()).get("tag_name", ""))' <<< "$gh_resp" 2>/dev/null || true)
                    else
                        LATEST_TAG=$(sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$gh_resp" | head -n 1)
                    fi
                fi
            fi
            [ -n "$LATEST_TAG" ] || LATEST_TAG="v26.10.21"
            CLEAN_LATEST="${LATEST_TAG#v}"

            if [ -z "$CURRENT_VER" ] || [ "$CURRENT_VER" != "$CLEAN_LATEST" ]; then
                log "Обновление ядра Xray до последней версии ($CURRENT_VER -> $LATEST_TAG)..."
                TMP_XRAY_DIR="/tmp/xray_update_$$"
                mkdir -p "$TMP_XRAY_DIR"
                XRAY_ZIP="$TMP_XRAY_DIR/xray.zip"
                
                DL_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_TAG}/Xray-linux-${XRAY_ARCH}.zip"
                if curl -fsSL --connect-timeout 15 "$DL_URL" -o "$XRAY_ZIP" 2>/dev/null; then
                    python3 -c "import zipfile; zipfile.ZipFile('$XRAY_ZIP').extractall('$TMP_XRAY_DIR')" 2>/dev/null || true
                    if [ -f "$TMP_XRAY_DIR/xray" ]; then
                        chmod +x "$TMP_XRAY_DIR/xray"
                        if "$TMP_XRAY_DIR/xray" -version >/dev/null 2>&1; then
                            mkdir -p "$XRAY_BIN_DIR"
                            [ -f "$TARGET_BIN" ] && cp -f "$TARGET_BIN" "$TARGET_BIN.bak"
                            install -m 755 "$TMP_XRAY_DIR/xray" "$TARGET_BIN.tmp.$$"
                            mv -f "$TARGET_BIN.tmp.$$" "$TARGET_BIN"
                            
                            if "$TARGET_BIN" -version >/dev/null 2>&1; then
                                [ -f "$TARGET_BIN.bak" ] && rm -f "$TARGET_BIN.bak"
                                [ -f "$TMP_XRAY_DIR/geosite.dat" ] && cp -f "$TMP_XRAY_DIR/geosite.dat" "$XRAY_BIN_DIR/geosite.dat"
                                [ -f "$TMP_XRAY_DIR/geoip.dat" ] && cp -f "$TMP_XRAY_DIR/geoip.dat" "$XRAY_BIN_DIR/geoip.dat"
                                
                                INSTALLED_XRAY_VER="$LATEST_TAG"
                                ok "Ядро Xray успешно обновлено до последней версии $LATEST_TAG (было: ${CURRENT_VER:-неизвестно})!"
                            else
                                warn "Установленный бинарник Xray не запустился, выполняется откат."
                                [ -f "$TARGET_BIN.bak" ] && mv -f "$TARGET_BIN.bak" "$TARGET_BIN"
                                INSTALLED_XRAY_VER="${CURRENT_VER:-v26.7.28}"
                            fi
                        else
                            warn "Скачанный бинарник Xray $LATEST_TAG не прошел валидацию, сохранен текущий $CURRENT_VER."
                            INSTALLED_XRAY_VER="${CURRENT_VER:-v26.7.28}"
                        fi
                    fi
                else
                    warn "Не удалось скачать обновление Xray $LATEST_TAG с GitHub, используется $CURRENT_VER."
                    INSTALLED_XRAY_VER="${CURRENT_VER:-v26.7.28}"
                fi
                rm -rf "$TMP_XRAY_DIR"
            else
                INSTALLED_XRAY_VER="$LATEST_TAG"
                ok "Ядро Xray уже актуальной версии ($LATEST_TAG)."
            fi
        fi

        # Активация службы 3X-UI
        log "Активация службы 3X-UI..."
        if [ "${IS_DOCKER_XUI:-0}" -eq 1 ]; then
            (docker start 3x-ui-dokploy >/dev/null 2>&1 || docker start $(docker ps -aq --filter ancestor=ghcr.io/mhsanaei/3x-ui | head -n1) >/dev/null 2>&1) && ok "Контейнер 3X-UI успешно запущен." || warn "Не удалось запустить контейнер 3X-UI."
        else
            (svc_restart x-ui 2>/dev/null || svc_start x-ui 2>/dev/null || systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null || rc-service x-ui start 2>/dev/null) && ok "Служба 3X-UI успешно активирована." || warn "Не удалось активировать службу x-ui."
        fi
        sleep 2

        # Проверка Nginx на наличие мертвого SNI и мягкий reload
        if command -v nginx >/dev/null 2>&1; then
            if [ -d /etc/nginx ] && grep -rq "swdist\.microsoft\.com" /etc/nginx/ 2>/dev/null; then
                log "Обновление устаревшего SNI в конфигурационных файлах Nginx..."
                find /etc/nginx/ -type f -name "*.conf" -exec sed -i 's/swdist\.microsoft\.com/gateway\.icloud\.com/g' {} + 2>/dev/null || true
                ok "Nginx: SNI swdist.microsoft.com заменен на gateway.icloud.com."
            fi

            if nginx -t >/dev/null 2>&1; then
                systemctl reload nginx 2>/dev/null && ok "Nginx успешно применил конфигурацию (Zero Downtime reload)." || true
            fi
        fi
    fi

    # Чтение параметров единого клиента, экспортированных из Python
    UNIFIED_CLIENT_TAG=""
    UNIFIED_SUB_ID=""
    UNIFIED_VLESS_ENKEY=""
    SS2022_URI=""
    TUIC_URI=""
    MTPROTO_TG_URI=""
    MTPROTO_HTTPS_URI=""
    MTPROTO_SECRET=""
    MTPROTO_BOT_SECRET=""
    MASQUE_URI=""
    SHADOWTLS_URI=""
    SS_SHADOWTLS_URI=""
    WSTUNNEL_CLI=""
    WSTUNNEL_URI=""
    ZAPRET_INFO=""
    NAIVE_URI=""
    DNSTT_CLI=""
    DNSTT_PUBKEY=""
    for c_env in "/run/3xui_unified_client.env" "/tmp/3xui_unified_client.env"; do
        if [ -f "$c_env" ]; then
            # shellcheck disable=SC1090
            source "$c_env"
            break
        fi
    done

    if [ -z "${DNSTT_PUBKEY:-}" ] && [ -f "/etc/dnstt/server.pub" ]; then
        DNSTT_PUBKEY="$(cat /etc/dnstt/server.pub 2>/dev/null | tr -d '[:space:]')"
    fi
    if [ -n "${DNSTT_PUBKEY:-}" ]; then
        if [ -n "${DNSTT_CLI:-}" ] && [[ "$DNSTT_CLI" == *"-pubkey  "* ]]; then
            DNSTT_CLI="${DNSTT_CLI/-pubkey  /-pubkey ${DNSTT_PUBKEY} }"
        fi
    fi

    echo
    echo -e "${GREEN}=====================================================================${NC}"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo -e "${YELLOW}               АУДИТ УСПЕШНО ЗАВЕРШЕН (DRY-RUN)                      ${NC}"
        echo -e "${CYAN}  Для применения изменений выполните:                                ${NC}"
        echo -e "  ${BOLD}./configure-panel.sh --config \"${CONFIG_FILE:-./server-setup.env}\" -y${NC}"
    else
        echo -e "${GREEN}      БАЗА ДАННЫХ 3X-UI УСПЕШНО СКОНФИГУРИРОВАНА И ИСЦЕЛЕНА!         ${NC}"
        echo -e "  - ${BOLD}Единый клиент:${NC}         ${GREEN}${UNIFIED_CLIENT_TAG:-Client}${NC} (объединяет до 9 протоколов в 1 профиль)"
        if [ -n "$INSTALLED_XRAY_VER" ]; then
            echo -e "  - ${BOLD}Ядро Xray-core:${NC}        ${GREEN}${INSTALLED_XRAY_VER}${NC} (Latest Official Release)"
        fi
        local disp_sub_host="${SUB_DOMAIN:-$PRIMARY_DOMAIN}"
        local disp_panel_host="${PANEL_DOMAIN:-$PRIMARY_DOMAIN}"
        local clean_p_path="${PANEL_PATH#/}"
        local clean_s_path="${SUB_PATH#/}"
        local clean_sc_path="${SUB_CLASH_PATH#/}"
        [ -n "$clean_p_path" ] && clean_p_path="${clean_p_path%/}/"
        [ -n "$clean_s_path" ] && clean_s_path="${clean_s_path%/}/"
        [ -n "$clean_sc_path" ] && clean_sc_path="${clean_sc_path%/}/"

        echo -e "  - ${BOLD}Панель управления:${NC}      ${CYAN}https://${disp_panel_host}/${clean_p_path}${NC}"
        echo -e "  - ${BOLD}Логин панели:${NC}           ${WHITE}${ADMIN_USERNAME:-admin}${NC}"
        if [ -n "${ADMIN_PASSWORD:-}" ]; then
            echo -e "  - ${BOLD}Пароль панели:${NC}          ${WHITE}${ADMIN_PASSWORD}${NC}"
        fi
        echo -e "  - ${BOLD}Канал подписок:${NC}        ${CYAN}https://${disp_sub_host}/${clean_s_path}${NC}"
        echo -e "  - ${BOLD}Канал подписок (Clash):${NC}  ${CYAN}https://${disp_sub_host}/${clean_sc_path}${NC}"
        if [ -n "${UNIFIED_SUB_ID:-}" ]; then
            echo -e "  - ${BOLD}Прямая подписка:${NC}       ${GREEN}https://${disp_sub_host}/${clean_s_path}${UNIFIED_SUB_ID}${NC}"
            echo -e "  - ${BOLD}Прямая подписка (Clash):${NC} ${GREEN}https://${disp_sub_host}/${clean_sc_path}${UNIFIED_SUB_ID}${NC}"
        fi
        if [ -n "${UNIFIED_VLESS_ENKEY:-}" ]; then
            echo -e "  - ${BOLD}VLESS xHTTP EnKey:${NC}     ${YELLOW}${UNIFIED_VLESS_ENKEY}${NC} (ML-KEM-768)"
        fi
        if [ -n "${UNIFIED_AWG_HPK:-}" ]; then
            echo -e "  - ${BOLD}AmneziaWG v3.1 HPK:${NC}     ${YELLOW}${UNIFIED_AWG_HPK}${NC} (UDP :${UNIFIED_AWG_PORT:-8443})"
        fi
        if [ -n "${SS2022_URI:-}" ]; then
            echo -e "  - ${BOLD}Shadowsocks 2022:${NC}    ${CYAN}${SS2022_URI}${NC}"
        fi
        if [ -n "${TUIC_URI:-}" ]; then
            echo -e "  - ${BOLD}TUIC v5 (QUIC+BBR):${NC}  ${CYAN}${TUIC_URI}${NC}"
        fi
        if [ -n "${MTPROTO_TG_URI:-}" ]; then
            echo -e "  - ${BOLD}Telegram MTProxy:${NC}     ${CYAN}${MTPROTO_TG_URI}${NC}"
            echo -e "  - ${BOLD}MTProxy Web Link:${NC}     ${CYAN}${MTPROTO_HTTPS_URI}${NC}"
            if [ -n "${MTPROTO_BOT_SECRET:-}" ]; then
                echo -e "  - ${BOLD}Ключ для @MTProxybot:${NC} ${YELLOW}${MTPROTO_BOT_SECRET}${NC} (боту передавать строго эти 32 символа!)"
            fi
        fi
        if [ -n "${MASQUE_URI:-}" ]; then
            echo -e "  - ${BOLD}MASQUE (RFC 9484):${NC}    ${CYAN}${MASQUE_URI}${NC}"
        fi
        if [ -n "${SHADOWTLS_URI:-}" ]; then
            echo -e "  - ${BOLD}ShadowTLS v4:${NC}         ${CYAN}${SHADOWTLS_URI}${NC}"
            echo -e "  - ${BOLD}ShadowTLS + SS-2022:${NC}  ${CYAN}${SS_SHADOWTLS_URI}${NC}"
        fi
        if [ -n "${WSTUNNEL_CLI:-}" ]; then
            echo -e "  - ${BOLD}Wstunnel CLI:${NC}         ${CYAN}${WSTUNNEL_CLI}${NC}"
        fi
        if [ -n "${ZAPRET_INFO:-}" ]; then
            echo -e "  - ${BOLD}Server-Side Zapret:${NC}   ${GREEN}${ZAPRET_INFO}${NC}"
        fi
        if [ -n "${NAIVE_URI:-}" ]; then
            echo -e "  - ${BOLD}NaïveProxy:${NC}          ${CYAN}${NAIVE_URI}${NC}"
        fi
        if [ -n "${DNSTT_CLI:-}" ]; then
            echo -e "  - ${BOLD}DNSTT DoH Tunnel:${NC}    ${CYAN}${DNSTT_CLI}${NC}"
        fi
        local _node_tok_en="${ENABLE_NODE_TOKEN:-n}"
        if [[ "${_node_tok_en,,}" == "y" || "${_node_tok_en}" == "1" ]] && [ -n "${NODE_TOKEN:-}" ]; then
            echo -e "  - ${BOLD}3X-UI Node API:${NC}         ${GREEN}${NODE_TOKEN_NAME:-Node}${NC} (Host: ${CYAN}${PRIMARY_DOMAIN}:443${NC}, Path: ${CYAN}/${PANEL_PATH#/}/${NC})"
            echo -e "  - ${BOLD}API Bearer Token:${NC}       ${YELLOW}${NODE_TOKEN}${NC}"
        fi
        if [ "${HAS_SELF_SIGNED_CERTS:-0}" -eq 1 ] || [ -f /etc/nginx/.self_signed_warning ]; then
            echo -e "  - ${BOLD}Статус SSL:${NC}             ${YELLOW}${BOLD}⚠️  ВРЕМЕННЫЙ САМОПОДПИСАННЫЙ (ТРЕБУЕТСЯ ЗАМЕНА!)${NC}"
        fi
    fi

    # Сохранение учетных данных в защищенный файл
    if [ "$DRY_RUN" -eq 0 ]; then
        CRED_FILE="/root/vpn_credentials.txt"
        if [ -n "${ADMIN_PASSWORD:-}" ]; then
            cat << EOF_CRED > "$CRED_FILE"
=====================================================================
УЧЕТНЫЕ ДАННЫЕ ПАНЕЛИ И СЕРВИСОВ 3X-UI
Файл обновлен: $(date '+%Y-%m-%d %H:%M:%S')
=====================================================================
Панель управления:     https://${PRIMARY_DOMAIN}${PANEL_PATH}
$([ -n "${DIAG_TOKEN:-}" ] && echo "Веб-диагностика (SSO): https://${PRIMARY_DOMAIN}${PANEL_PATH}diag")
$([ -n "${DIAG_TOKEN:-}" ] && echo "Токен диагностики:     ${DIAG_TOKEN}")
Логин администратора:   ${ADMIN_USERNAME:-admin}
Пароль администратора:  ${ADMIN_PASSWORD}
$([ -n "$INSTALLED_XRAY_VER" ] && echo "Ядро Xray-core:        ${INSTALLED_XRAY_VER}")
$([ "${HAS_SELF_SIGNED_CERTS:-0}" -eq 1 ] || [ -f /etc/nginx/.self_signed_warning ] && echo "Статус SSL:            ⚠️ ВРЕМЕННЫЙ САМОПОДПИСАННЫЙ (ТРЕБУЕТСЯ ЗАМЕНА!)")

Единый клиент:          ${UNIFIED_CLIENT_TAG:-Client}
Канал подписок:        https://${PRIMARY_DOMAIN}/${SUB_PATH#/}/
Канал подписок (Clash): https://${PRIMARY_DOMAIN}/${SUB_CLASH_PATH#/}/
Прямая ссылка подписки: https://${PRIMARY_DOMAIN}/${SUB_PATH#/}/${UNIFIED_SUB_ID}
Прямая ссылка (Clash):  https://${PRIMARY_DOMAIN}/${SUB_CLASH_PATH#/}/${UNIFIED_SUB_ID}
$([ -n "${UNIFIED_VLESS_ENKEY:-}" ] && echo "VLESS xHTTP EnKey:     ${UNIFIED_VLESS_ENKEY} (ML-KEM-768)")
$([ -n "${UNIFIED_AWG_HPK:-}" ] && echo "AmneziaWG v3.1 HPK:    ${UNIFIED_AWG_HPK} (UDP :${UNIFIED_AWG_PORT:-8443})")
$([ -n "${SS2022_URI:-}" ] && printf "Shadowsocks 2022:       %s\n" "${SS2022_URI}")
$([ -n "${TUIC_URI:-}" ] && printf "TUIC v5 (QUIC+BBR):     %s\n" "${TUIC_URI}")
$([ -n "${MTPROTO_TG_URI:-}" ] && printf "Telegram MTProxy (Клиент): %s\nMTProxy Web Link:          %s\nMTProxy FakeTLS Secret:    %s\n$([ -n "${MTPROTO_BOT_SECRET:-}" ] && printf "MTProxy Key для @MTProxybot: %s (ВНИМАНИЕ: боту передавать строго эти 32 символа! Ссылку от бота клиентам не давать)\n" "${MTPROTO_BOT_SECRET}")" "${MTPROTO_TG_URI}" "${MTPROTO_HTTPS_URI}" "${MTPROTO_SECRET:-}")
$([ -n "${MASQUE_URI:-}" ] && printf "MASQUE (RFC 9484):       %s\n" "${MASQUE_URI}")
$([ -n "${SHADOWTLS_URI:-}" ] && printf "ShadowTLS v4:            %s\nShadowTLS + SS-2022:     %s\n" "${SHADOWTLS_URI}" "${SS_SHADOWTLS_URI}")
$([ -n "${WSTUNNEL_CLI:-}" ] && printf "Wstunnel Client CLI:     %s\n" "${WSTUNNEL_CLI}")
$([ -n "${ZAPRET_INFO:-}" ] && printf "Server-Side Zapret:      %s\n" "${ZAPRET_INFO}")
$([ -n "${NAIVE_URI:-}" ] && printf "NaïveProxy (Chrome HTTPS): %s\n" "${NAIVE_URI}")
$([ -n "${DNSTT_CLI:-}" ] && printf "DNSTT DoH Tunnel:        %s\nDNSTT Public Key:        %s\n" "${DNSTT_CLI}" "${DNSTT_PUBKEY}")
$([ -n "${MIERU_PORT:-}" ] && [ -n "${MIERU_USER:-}" ] && printf "Mieru Proxy (XChaCha20, :%s): user: %s, pass: %s (Клиентский конфиг: /root/mieru-client.json, управление: mieru-mgr)\n" "${MIERU_PORT}" "${MIERU_USER}" "${MIERU_PASS}")
$([ -n "${NODE_TOKEN:-}" ] && printf "3X-UI Node Token:      %s\nИмя ноды (Node Name):  %s (Host: %s:443, Path: /%s/)\n" "${NODE_TOKEN}" "${NODE_TOKEN_NAME}" "${PRIMARY_DOMAIN}" "${PANEL_PATH#/}")
(Объединяет все конфигурации: Steal REALITY, Classic REALITY, xHTTP, Hysteria 2, AWG v3, AWG v2, SS-2022, TUIC v5, MTProxy, MASQUE, ShadowTLS, Wstunnel, Zapret, NaïveProxy, DNSTT, Mieru)
Команда для удаления:  vpn-uninstall (или curl -sSL "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/uninstall.sh" | sudo bash)
=====================================================================
EOF_CRED
            if [ "${HAS_SELF_SIGNED_CERTS:-0}" -eq 1 ] || [ -f /etc/nginx/.self_signed_warning ]; then
                cat << 'EOF_SSL_WARN_CRED' >> "$CRED_FILE"
=====================================================================
⚠️  ВНИМАНИЕ: ИСПОЛЬЗУЕТСЯ ВРЕМЕННЫЙ САМОПОДПИСАННЫЙ SSL-СЕРТИФИКАТ
Для одного или нескольких доменов не удалось выпустить Let's Encrypt SSL.
• Браузер при входе в панель 3X-UI будет выдавать предупреждение безопасности.
• Клиентские подписки, VLESS xHTTP и Hysteria 2 не будут подключаться,
  пока не будет получен доверенный публичный сертификат.
• Инбаунды REALITY, AmneziaWG и Shadowsocks-2022 работают штатно.

КОМАНДА ДЛЯ ПЕРЕВЫПУСКА СЕРТИФИКАТА (после настройки DNS A-записей):
• Рекомендуемый быстрый способ (только SSL, без простоя VPN):
  bash maintain.sh -ssl
• Полный перезапуск мастера установки (если установка прерывалась):
  bash setup.sh -r
EOF_SSL_WARN_CRED
            fi
            echo -e "  - ${BOLD}Файл с паролями:${NC}        ${CYAN}$CRED_FILE${NC} (chmod 600)"
        elif [ -f "$CRED_FILE" ]; then
            if [ "${HAS_SELF_SIGNED_CERTS:-0}" -eq 1 ] || [ -f /etc/nginx/.self_signed_warning ]; then
                if ! grep -q "САМОПОДПИСАННЫЙ SSL-СЕРТИФИКАТ" "$CRED_FILE" 2>/dev/null; then
                    cat << 'EOF_SSL_WARN_CRED' >> "$CRED_FILE"
=====================================================================
⚠️  ВНИМАНИЕ: ИСПОЛЬЗУЕТСЯ ВРЕМЕННЫЙ САМОПОДПИСАННЫЙ SSL-СЕРТИФИКАТ
Для одного или нескольких доменов не удалось выпустить Let's Encrypt SSL.
• Браузер при входе в панель 3X-UI будет выдавать предупреждение безопасности.
• Клиентские подписки, VLESS xHTTP и Hysteria 2 не будут подключаться,
  пока не будет получен доверенный публичный сертификат.
• Инбаунды REALITY, AmneziaWG и Shadowsocks-2022 работают штатно.

КОМАНДА ДЛЯ ПЕРЕВЫПУСКА СЕРТИФИКАТА (после настройки DNS A-записей):
• Рекомендуемый быстрый способ (только SSL, без простоя VPN):
  bash maintain.sh -ssl
• Полный перезапуск мастера установки (если установка прерывалась):
  bash setup.sh -r
EOF_SSL_WARN_CRED
                fi
            fi
            if [ -n "${MASQUE_URI:-}" ] && ! grep -q "MASQUE (RFC 9484):" "$CRED_FILE" 2>/dev/null; then
                echo "MASQUE (RFC 9484):       ${MASQUE_URI}" >> "$CRED_FILE"
            fi
            if [ -n "${SHADOWTLS_URI:-}" ] && ! grep -q "ShadowTLS v4:" "$CRED_FILE" 2>/dev/null; then
                echo "ShadowTLS v4:            ${SHADOWTLS_URI}" >> "$CRED_FILE"
                echo "ShadowTLS + SS-2022:     ${SS_SHADOWTLS_URI}" >> "$CRED_FILE"
            fi
            if [ -n "${WSTUNNEL_CLI:-}" ] && ! grep -q "Wstunnel Client CLI:" "$CRED_FILE" 2>/dev/null; then
                echo "Wstunnel Client CLI:     ${WSTUNNEL_CLI}" >> "$CRED_FILE"
            fi
            if [ -n "${ZAPRET_INFO:-}" ] && ! grep -q "Server-Side Zapret:" "$CRED_FILE" 2>/dev/null; then
                echo "Server-Side Zapret:      ${ZAPRET_INFO}" >> "$CRED_FILE"
            fi
            if [ -n "${NAIVE_URI:-}" ] && ! grep -q "NaïveProxy (Chrome HTTPS):" "$CRED_FILE" 2>/dev/null; then
                echo "NaïveProxy (Chrome HTTPS): ${NAIVE_URI}" >> "$CRED_FILE"
            fi
            if [ -n "${DNSTT_CLI:-}" ] && ! grep -q "DNSTT DoH Tunnel:" "$CRED_FILE" 2>/dev/null; then
                echo "DNSTT DoH Tunnel:        ${DNSTT_CLI}" >> "$CRED_FILE"
                echo "DNSTT Public Key:        ${DNSTT_PUBKEY}" >> "$CRED_FILE"
            fi
            if [ -n "${MIERU_PORT:-}" ] && [ -n "${MIERU_USER:-}" ] && ! grep -q "Mieru Proxy" "$CRED_FILE" 2>/dev/null; then
                echo "Mieru Proxy (XChaCha20, :${MIERU_PORT}): user: ${MIERU_USER}, pass: ${MIERU_PASS}" >> "$CRED_FILE"
                echo "  Клиентский конфиг: /root/mieru-client.json (Управление пользователями: mieru-mgr list|add|del)" >> "$CRED_FILE"
            fi
            echo -e "  - ${BOLD}Файл с паролями:${NC}        ${CYAN}$CRED_FILE${NC} (обновлен, chmod 600)"
        fi
        chmod 600 "$CRED_FILE" 2>/dev/null || true
    fi
    if [ "${HAS_SELF_SIGNED_CERTS:-0}" -eq 1 ] || [ -f /etc/nginx/.self_signed_warning ]; then
        echo -e "${YELLOW}┌────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}│  ⚠️  НАПОМИНАНИЕ: НЕОБХОДИМО ЗАМЕНИТЬ САМОПОДПИСАННЫЙ SSL-СЕРТИФИКАТ  │${NC}"
        echo -e "${YELLOW}├────────────────────────────────────────────────────────────────────────┤${NC}"
        echo -e "${YELLOW}│  Для работы подписок и VLESS xHTTP / Hysteria 2 на клиентах привяжите  │${NC}"
        echo -e "${YELLOW}│  домен и запустите перевыпуск:                                         │${NC}"
        echo -e "${YELLOW}│  • Быстро обновить SSL (без простоя VPN):  ${GREEN}bash maintain.sh -ssl${YELLOW}       │${NC}"
        echo -e "${YELLOW}│  • Перезапуск всей установки с чекпоинта:  ${GREEN}bash setup.sh -r${YELLOW}            │${NC}"
        echo -e "${YELLOW}└────────────────────────────────────────────────────────────────────────┘${NC}"
    fi
    echo -e "${GREEN}=====================================================================${NC}"
    echo
    return 0
}

configure_3xui_panel "$@"
