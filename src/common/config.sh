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

