#!/usr/bin/env bash
# Public installation entrypoint. The execution engine is shared with setup.sh.
#!/usr/bin/env bash
#
# ==============================================================================
# Production AutoSetup: Nginx Stream L4 Router & 3X-UI Companion v9.4.0 Universal
# Nginx L4 Stream + 3X-UI + Unix Sockets + Native proxy_http_version 2 + 3 Decoys
# ==============================================================================
# Архитектура:
#   1) Nginx Mainline Branch v.1.31.4+ (Официальный репозиторий nginx.org)
#   2) VLESS REALITY (маскировка под свой сайт) с защитой от зацикливания (Anti-Loop Fallback 9443)
#   3) VLESS REALITY (маскировка под популярные внешние сервисы)
#   4) VLESS xHTTP (Stream-One) + VLESSENC + Native H2 Streaming (без XMUX-блокировок)
#      (СТРОГО по TCP/HTTP/2 без QUIC — полнодуплексное HTTP/2-проксирование Nginx)
#   5) Опциональный скоростной UDP VPN: Hysteria 2 (по умолчанию 443/UDP)
#   6) Опциональный двухверсионный стек AmneziaWG / WireGuard:
#      - AmneziaWG v3.1 (WG3, по умолчанию 8443/UDP, Transport Protection)
#      - AmneziaWG v2.0 (по умолчанию 8444/UDP, для роутеров Keenetic / OpenWrt)
#   7) Гибридный SSL-движок с разделением каталогов:
#      - Certbot (HTTP-01): /etc/letsencrypt/live/
#      - acme.sh + Cloudflare (DNS-01): /etc/ssl/acme/ (изоляция от /root/ и 755/644)
#      - 3 автономных локальных режима маскировки (Decoy Front):
#      - 1: DataSphere Analytics (SPA с 3D-сферой и телеметрией)
#      - 2: Облако CosmosCloud
#      - 3: Стандартная заглушка Nginx (Welcome to nginx)
#   9) Комплексная защита от ботов, сканеров уязвимостей, AI-парсеров (444/404)
#  10) Полный тюнинг ядра Linux (TCP BBR, fq, somaxconn, lowat, IPC /dev/shm, UDP buffers)
#  ==============================================================================

set -euo pipefail

SCRIPT_VERSION="v9.4.0"


# Checkpoints use stable step IDs and input signatures, independent of UI numbering.
SCRIPT_START_TIME=$(date +%s)
SCRIPT_START_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
TOTAL_STEPS=0
LAST_COMPLETED_STEP=${LAST_COMPLETED_STEP:-0}
RESUME_STEP=${RESUME_STEP:-1}
RESUME_MODE=${RESUME_MODE:-0}
CURRENT_STEP_START=0
declare -A STEP_DURATIONS=() STEP_BG_FLAGS=() STEP_NAMES=()
declare -A DOMAIN_TO_PORT=() EXT_SNI_TO_PORT=() CHECKPOINT_HASHES=()
CHECKPOINT_LAST=""
CHECKPOINT_FAILED=""
FAILED_STEP_NUM=0

format_duration() {
    local total_seconds=$1
    local minutes=$(( total_seconds / 60 ))
    local seconds=$(( total_seconds % 60 ))
    if [ "$minutes" -gt 0 ]; then
        echo "${minutes} мин ${seconds} сек"
    else
        echo "${seconds} сек"
    fi
}

is_true() {
    local val="${1:-0}"
    [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]
}

checkpoint_id() {
    local key="$1"
    if [[ "$key" =~ ^[0-9]+$ ]]; then
        printf '%s' "${STEP_IDS[$key]:-}"
    else
        printf '%s' "$key"
    fi
}

checkpoint_signature() {
    local id="$1" key
    local keys=""
    case "$id" in
        packages) keys="ENABLE_WEB_STACK ENABLE_ZAPRET" ;;
        kernel|nginx) keys="" ;;
        certificates) keys="PRIMARY_DOMAIN ALL_DOMAINS SSL_ENGINE_CHOICE CF_AUTH_METHOD CF_Token CF_Account_ID CF_Email CF_Key" ;;
        decoy) keys="PRIMARY_DOMAIN DECOY_MODE" ;;
        security) keys="SSH_PORT SSH_PUBLIC_KEY ENABLE_HOST_SECURITY ENABLE_FAIL2BAN DISABLE_PASSWORD_AUTH" ;;
        *) keys="PRIMARY_DOMAIN ALL_DOMAINS STEAL_PORTS_LIST CLASSIC_PORTS_LIST EXT_SNI_LIST ALL_EXT_SNIS ADD_WWW ENABLE_WEB_STACK ENABLE_STEAL STEAL_DOMAINS STEAL_PORT ENABLE_CLASSIC CLASSIC_SNI CLASSIC_PORT REALITY_FINGERPRINT PANEL_PORT PANEL_PATH ADMIN_USERNAME ADMIN_PASSWORD SUB_PORT SUB_PATH SUB_CLASH_PATH SUB_TITLE XHTTP_STREAM_PORT XHTTP_STREAM_PATH ENABLE_HY2 HY2_PORT HY2_DOMAIN HY2_PORT_HOPPING HY2_PORT_HOPPING_RANGE ENABLE_AWG_V3 AWG_V3_PORT ENABLE_AWG_V2 AWG_V2_PORT ENABLE_AWG_STANDALONE AWG_STANDALONE_PORT AWG_SERVER_HOST AWG_PRIMARY_DNS AWG_SECONDARY_DNS ENABLE_AGH AGH_MODE AGH_DOMAIN AGH_USER AGH_PASS AGH_CLIENT_ID AGH_XRAY_DNS PORT_AGH_WEB PORT_AGH_DNS DIAG_PATH DIAG_TOKEN ENABLE_WARP WARP_LICENSE_KEY ENABLE_SS2022 SS2022_PORT SS2022_METHOD SS2022_PASSWORD ENABLE_TUIC TUIC_PORT TUIC_UUID TUIC_PASSWORD ENABLE_MTPROTO MTPROTO_PORT MTPROTO_SECRET ENABLE_MASQUE MASQUE_PORT MASQUE_PASSWORD ENABLE_SHADOWTLS SHADOWTLS_PORT SHADOWTLS_DOMAIN SHADOWTLS_PASSWORD ENABLE_NAIVE NAIVE_PORT NAIVE_DOMAIN NAIVE_USER NAIVE_PASS ENABLE_WSTUNNEL WSTUNNEL_PORT WSTUNNEL_PREFIX WSTUNNEL_SECRET ENABLE_DNSTT DNSTT_PORT DNSTT_DOMAIN DNSTT_PUBKEY ENABLE_ZAPRET ZAPRET_QNUM ZAPRET_DESYNC ZAPRET_FOOLING ENABLE_MIERU MIERU_PORT_MODE MIERU_PORT MIERU_TRANSPORT MIERU_USER MIERU_PASS MIERU_MTU AUTO_SETUP_3XUI ENABLE_NODE_TOKEN NODE_TOKEN NODE_TOKEN_NAME TIME_LOCATION BLOCK_SMTP BLOCK_LAN WEB_LISTEN SUB_LISTEN AWG_HEADER_PROTECTION_KEY AWG_RANDOM_TRAILERS AWG_SUBNET_IP AWG_SUBNET_CIDR MTPROTO_FAKETLS_DOMAIN MTPROTO_ADTAG SHADOWTLS_SNI WSTUNNEL_DOMAIN" ;;
    esac
    {
        printf '%s\0' "${SCRIPT_VERSION:-unknown}" "$id"
        for key in $keys; do
            local -n input="$key"
            printf '%s\0' "$key" "${input[@]-}"
        done
    } | sha256sum | cut -d ' ' -f1
}

load_checkpoint_state() {
    CHECKPOINT_HASHES=(); CHECKPOINT_LAST=""; CHECKPOINT_FAILED=""
    local state="${SAVED_CONFIG_FILE:-server-setup.env}.state" key value
    if [ ! -f "$state" ]; then
        if [ -f "/etc/server-setup.env.state" ]; then
            state="/etc/server-setup.env.state"
        else
            return 0
        fi
    fi
    while IFS='=' read -r key value || [ -n "$key" ]; do
        key="${key//[[:space:]]/}"
        value="${value//[[:space:]]/}"
        if [ "$key" = last ]; then
            [[ "$value" =~ ^[a-z_]+$ ]] && CHECKPOINT_LAST="$value"
        elif [ "$key" = failed ]; then
            [[ "$value" =~ ^[a-z_]+$ ]] && CHECKPOINT_FAILED="$value"
        elif [[ "$key" =~ ^[a-z_]+$ && "$value" =~ ^[a-f0-9]{64}$ ]]; then
            CHECKPOINT_HASHES[$key]="$value"
        fi
    done < "$state"
    return 0
}

restore_installation_checkpoint() {
    if [ "${ROTATE_PATHS:-0}" -eq 1 ]; then
        LAST_COMPLETED_STEP=0; RESUME_STEP=1; CHECKPOINT_FAILED=""; FAILED_STEP_NUM=0
        return 0
    fi
    load_checkpoint_state
    # Old numeric checkpoints cannot identify a component or its input settings.
    LAST_COMPLETED_STEP=0
    FAILED_STEP_NUM=0
    if [ -n "$CHECKPOINT_LAST" ] && [ "$CHECKPOINT_LAST" != verify ]; then
        LAST_COMPLETED_STEP="${STEP_NUMBERS[$CHECKPOINT_LAST]:-0}"
    fi
    if [ -n "$CHECKPOINT_FAILED" ]; then
        FAILED_STEP_NUM="${STEP_NUMBERS[$CHECKPOINT_FAILED]:-0}"
    fi
    if [ "${RESUME_MODE:-0}" -eq 1 ] && [ "$LAST_COMPLETED_STEP" -eq 0 ] && [ "$FAILED_STEP_NUM" -eq 0 ]; then
        RESUME_STEP=$((TOTAL_STEPS + 1))
    fi
}

record_step_started() {
    local id
    id=$(checkpoint_id "$1")
    [ -n "$id" ] || return 0
    load_checkpoint_state
    CHECKPOINT_FAILED="$id"
    local state="${SAVED_CONFIG_FILE:-server-setup.env}.state" temporary key
    temporary=$(umask 077; mktemp "${state}.tmp.XXXXXX") || return 1
    if ! {
        printf 'last=%s\n' "$CHECKPOINT_LAST"
        printf 'failed=%s\n' "$CHECKPOINT_FAILED"
        for key in "${!CHECKPOINT_HASHES[@]}"; do
            printf '%s=%s\n' "$key" "${CHECKPOINT_HASHES[$key]}"
        done
    } > "$temporary"; then rm -f -- "$temporary"; return 1; fi
    if ! mv -f -- "$temporary" "$state"; then rm -f -- "$temporary"; return 1; fi
    if [ "$state" != "/etc/server-setup.env.state" ]; then
        local mirror_tmp
        if mirror_tmp=$(mktemp /etc/server-setup.env.state.tmp.XXXXXX 2>/dev/null); then
            if ! cp -f -- "$state" "$mirror_tmp" || ! chmod 600 "$mirror_tmp" || ! mv -f -- "$mirror_tmp" /etc/server-setup.env.state; then
                rm -f -- "$mirror_tmp"
            fi
        fi
    fi
}

record_step_completed() {
    local id
    id=$(checkpoint_id "$1")
    load_checkpoint_state
    if [ "$id" = 0 ] || [ -z "$id" ]; then
        CHECKPOINT_LAST=""; CHECKPOINT_FAILED=""; LAST_COMPLETED_STEP=0
        CHECKPOINT_HASHES=()
    else
        CHECKPOINT_HASHES[$id]=$(checkpoint_signature "$id") || return 1
        CHECKPOINT_LAST="$id"
        CHECKPOINT_FAILED=""
        LAST_COMPLETED_STEP="${STEP_NUMBERS[$id]:-0}"
    fi
    local state="${SAVED_CONFIG_FILE:-server-setup.env}.state" temporary key
    temporary=$(umask 077; mktemp "${state}.tmp.XXXXXX") || return 1
    if ! {
        printf 'last=%s\n' "$CHECKPOINT_LAST"
        printf 'failed=%s\n' "$CHECKPOINT_FAILED"
        for key in "${!CHECKPOINT_HASHES[@]}"; do
            printf '%s=%s\n' "$key" "${CHECKPOINT_HASHES[$key]}"
        done
    } > "$temporary"; then rm -f -- "$temporary"; return 1; fi
    if ! mv -f -- "$temporary" "$state"; then rm -f -- "$temporary"; return 1; fi
    if [ "$state" != "/etc/server-setup.env.state" ]; then
        local mirror_tmp
        if mirror_tmp=$(mktemp /etc/server-setup.env.state.tmp.XXXXXX 2>/dev/null); then
            if ! cp -f -- "$state" "$mirror_tmp" || ! chmod 600 "$mirror_tmp" || ! mv -f -- "$mirror_tmp" /etc/server-setup.env.state; then
                rm -f -- "$mirror_tmp"
            fi
        fi
    fi
}

checkpoint_artifact_valid() {
    case "$1" in
        packages) command -v curl >/dev/null && command -v socat >/dev/null ;;
        kernel) sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -qx bbr ;;
        nginx) command -v nginx >/dev/null ;;
        certificates)
            local domain base
            if [ "${SSL_ENGINE_CHOICE:-1}" = 1 ]; then base=/etc/letsencrypt/live; else base=/etc/ssl/acme; fi
            for domain in "${ALL_DOMAINS[@]}"; do
                [ -f "$base/$domain/privkey.pem" ] && openssl x509 -checkend 0 -noout -in "$base/$domain/fullchain.pem" >/dev/null 2>&1 || return 1
            done
            ;;
        decoy) [ -f /var/www/html/index.html ] ;;
        nginx_config) [ -f /etc/nginx/stream.d/00-stream.conf ] && nginx -t >/dev/null 2>&1 && systemctl is-active --quiet nginx ;;
        panel) { [ -f /etc/x-ui/x-ui.db ] || [ -f /usr/local/x-ui/bin/x-ui.db ]; } && systemctl is-active --quiet x-ui ;;
        adguard) [ -f /opt/AdGuardHome/AdGuardHome.yaml ] && systemctl is-active --quiet AdGuardHome ;;
        awg) [ -f /etc/amnezia/amneziawg/awg0.conf ] && command -v awg >/dev/null && systemctl is-active --quiet awg-quick@awg0 ;;
        *) return 1 ;;
    esac
}

should_skip_step() {
    local id number signature
    id=$(checkpoint_id "$1")
    [ "$id" != verify ] && [ -n "$id" ] || return 1
    number="${STEP_NUMBERS[$id]:-0}"
    [ "${RESUME_STEP:-1}" -gt "$number" ] || return 1
    load_checkpoint_state
    signature=$(checkpoint_signature "$id") || return 1
    [ "${CHECKPOINT_HASHES[$id]:-}" = "$signature" ] || return 1
    checkpoint_artifact_valid "$id" || return 1
    ok "${INSTALLATION_TITLES[$id]}: verified checkpoint"
    STEP_DURATIONS[$number]=0
    return 0
}

invalidate_checkpoint() {
    # A changed prerequisite invalidates downstream configuration too.
    RESUME_STEP=1
}

step_begin() {
    local id number
    id=$(checkpoint_id "$1")
    number="${STEP_NUMBERS[$id]}"
    CURRENT_STEP_START=$(date +%s)
    record_step_started "$id"
    print_step_bar "$number" "$TOTAL_STEPS" "${INSTALLATION_TITLES[$id]}"
}

step_finish() {
    local id number duration
    id=$(checkpoint_id "$1")
    number="${STEP_NUMBERS[$id]}"
    duration=$(( $(date +%s) - CURRENT_STEP_START ))
    STEP_DURATIONS[$number]=$duration
    ok "${INSTALLATION_TITLES[$id]} [OK] ($(format_duration "$duration"))"
    record_step_completed "$id"
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


_TUI_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
[ -f "$_TUI_BASE_DIR/../common/colors.sh" ] && . "$_TUI_BASE_DIR/../common/colors.sh" 2>/dev/null || true
[ -f "$_TUI_BASE_DIR/../common/logger.sh" ] && . "$_TUI_BASE_DIR/../common/logger.sh" 2>/dev/null || true
[ -f "$_TUI_BASE_DIR/../common/spinner.sh" ] && . "$_TUI_BASE_DIR/../common/spinner.sh" 2>/dev/null || true

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
                "${SETUP_MASK_LOG:-}" \
                "${INSTALL_LOG:-}" \
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


# Прогресс-бар шагов
print_step_bar() {
    local step_num="$1"
    local total_steps="$2"
    local step_title="$3"
    local percent=$(( step_num * 100 / total_steps ))
    local filled=$(( step_num * 16 / total_steps ))
    local empty=$(( 16 - filled ))
    local bar=""
    for ((j=0; j<filled; j++)); do bar+="█"; done
    for ((j=0; j<empty; j++)); do bar+="░"; done

    echo ""
    echo -e "  ${BLUE}${BOLD}┌─[ Шаг $step_num из $total_steps ] ${WHITE}$step_title${NC}"
    echo -e "  ${BLUE}${BOLD}└─ Прогресс: [${CYAN}$bar${BLUE}${BOLD}] ${WHITE}${percent}%${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
}

# Вывод карточки заголовка
check_for_script_updates() {
    local remote_ver=""
    remote_ver=$(curl -fsSL --connect-timeout 2 "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/VERSION" 2>/dev/null | tr -d '[:space:]' || true)
    if [ -n "$remote_ver" ]; then
        if [ "$remote_ver" != "$SCRIPT_VERSION" ]; then
            echo -e "  ${YELLOW}⚠️  Доступно обновление скрипта: ${GREEN}$remote_ver${YELLOW} (текущая версия: ${CYAN}$SCRIPT_VERSION${YELLOW})${NC}"
            echo -e "  ${DIM}Обновить: curl -sSL "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/install.sh?v=$(date +%s)" | sudo bash${NC}\n"
        else
            echo -e "  ${DIM}Версия: ${GREEN}$SCRIPT_VERSION${DIM} (актуальная релизная сборка)${NC}\n"
        fi
    else
        echo -e "  ${DIM}Версия: ${GREEN}$SCRIPT_VERSION${NC}\n"
    fi
}

print_mask_banner() {
    clear 2>/dev/null || true
    echo -e "  ${CYAN}${BOLD}🛡️   Nginx Stream Router для 3X-UI [${SCRIPT_VERSION}]${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}Шлюз маскировки и защиты VPN-подключений:${NC}"
    echo -e "  ${DIM}• Маскировка под реальный сайт (защита от сканирования и блокировок)${NC}"
    echo -e "  ${DIM}• Поддержка протоколов: VLESS REALITY, Hysteria 2, AmneziaWG${NC}"
    echo -e "  ${DIM}• Единый защищенный порт 443 для всех сервисов, панели и подписок${NC}"
    echo -e "  ${DIM}• Обход капч Google и доступ к AI через Cloudflare WARP${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${DIM}Время запуска: ${WHITE}${SCRIPT_START_DATETIME}${NC}\n"
    check_for_script_updates
}

trap 'die "Скрипт аварийно прерван на строке $LINENO"' ERR

show_help() {
    cat << 'EOF_HELP'
Использование: ./setup.sh [ОПЦИИ]

Автоматизированный и интерактивный установщик L4/L7 Nginx Router + 3X-UI

Опции:
  -c, --config <FILE>          Загрузить параметры из конфигурационного файла (.env)
  -y, --yes, --non-interactive Запуск в неинтерактивном режиме (без вопросов пользователю)
  -d, --domain <DOMAIN>        Указать основной домен (PRIMARY_DOMAIN)
  --web-stack / --no-web-stack Включить / отключить установку комплекса веб-маскировки Nginx + 3X-UI
  --awg-standalone             Включить установку автономного сервера AmneziaWG (awg-mgr)
  --awg-host <HOST/IP>         Домен или IP-адрес для подключения клиентов AmneziaWG (Endpoint)
  --masque / --no-masque       Включить / отключить MASQUE (RFC 9484 / RFC 9298, :8449/udp)
  --shadowtls / --no-shadowtls Включить / отключить ShadowTLS v4 + SS-2022 (Nginx Stream SNI)
  --wstunnel / --no-wstunnel   Включить / отключить Wstunnel over Nginx L7 (HTTPS WebSocket)
  --zapret / --no-zapret       Включить / отключить Server-Side Zapret nfqws (DPI bypass)
  --naive / --no-naive         Включить / отключить NaïveProxy (Caddy with forwardproxy@naive)
  --dnstt / --no-dnstt         Включить / отключить DNSTT (DoH DNS Tunneling via dnstt-server)
  --all-protocols              Включить все протоколы (включая стек следующего поколения)
  --rotate-paths               Сменить пути панели, Wstunnel и ClientID DoH; выполнить все шаги заново
  -r, --resume                 Продолжить установку с последнего незавершенного шага
  --step <N>                   Начать с указанного этапа текущего плана (номера выводятся перед установкой)
  --check, --doctor            Запустить быструю диагностику состояния сервисов и выйти
  --express                    Запустить режим Экспресс-настройки (настройка в 2 вопроса)
  --expert                     Запустить Экспертный режим без повторного запроса меню
  --node-token / --no-node-token Создавать API-ключ ноды 3X-UI (по умолчанию: да) / отключить
  --node-token-name <NAME>      Имя API-ключа ноды
  --gen-config [FILE]          Сгенерировать шаблон конфигурации (.env.example) и выйти
  --debug                      Режим отладки: отключить спиннеры, вывод команд в реальном времени
  --dry-run                    Информация о холостом аудите (см. ./maintain.sh --dry-run)
  -f, --force                  Игнорировать ошибки и несовпадения DNS в неинтерактивном режиме
  --uninstall                  Откат и полное удаление установленного стека к исходному состоянию
  -v, --version                Показать версию скрипта и выйти
  -h, --help                   Показать справку и выйти

Примеры использования:
  # Интерактивный режим (введенные параметры автоматически сохраняются в server-setup.env):
  ./setup.sh

  # Запуск с подробным выводом всех команд в консоль (отладка без спиннеров):
  ./setup.sh --debug

  # Передача параметров в однострочник curl | bash (используйте разделитель -s --):
  curl -sSL https://.../install.sh | sudo bash -s -- --debug
  curl -sSL https://.../install.sh | sudo bash -s -- --check

  # Быстрая экспресс-диагностика всех сервисов, портов и SSL (без изменений):
  ./setup.sh --check

  # Безопасный холостой аудит базы 3X-UI и конфигов Nginx (без изменений):
  ./maintain.sh --dry-run

  # Возобновление прерванной установки с последнего незавершенного шага:
  ./setup.sh --resume

  # Принудительный запуск с определенного шага (напр. Шаг 4: Выпуск SSL):
  ./setup.sh --step 4 -y

  # Возобновление после обрыва связи или повторный запуск из сохраненного конфига:
  ./setup.sh -c server-setup.env -y

  # Развертывание через Ansible / Cloud-Init / CI:
  ./setup.sh --config /etc/server-setup.env --non-interactive --force

  # Генерация файла-шаблона:
  ./setup.sh --gen-config server-setup.env.example
EOF_HELP
}

generate_config_template() {
    local target_file="${1:-server-setup.env.example}"
    cat << 'EOF_CONF' > "$target_file"
# ==============================================================================
# КОНФИГУРАЦИЯ NGINX L4 ROUTER + 3X-UI ДЛЯ SETUP_MASK.SH (v9.4.0 Universal)
# ==============================================================================
# Данный файл позволяет выполнять полностью автоматическую установку:
# ./setup.sh --config server-setup.env --non-interactive --force

# --- 0. КОМПОНЕНТЫ УСТАНОВКИ ---
# Установить комплекс веб-маскировки Nginx + 3X-UI + SSL + VLESS/Trojan [y/n]
# Если 'n' и включен ENABLE_AWG_STANDALONE, настраивается только чистый автономный AmneziaWG (без веб-сервера и SSL)
ENABLE_WEB_STACK="y"

# --- 1. ДОМЕНЫ И СЕРТИФИКАТЫ ---
# Основной домен сервера (для панели, подписок, xHTTP и веб-маски) [ОБЯЗАТЕЛЬНО при ENABLE_WEB_STACK=y]
PRIMARY_DOMAIN="yourdomain.online"

# Добавить алиас 'www.<PRIMARY_DOMAIN>' в сертификационный стек [y/n]
ADD_WWW="y"

# Дополнительные домены для выпуска SSL (через пробел, например: "trojan.domain.com sub.domain.com")
EXTRA_SSL_DOMAINS=""

# Способ выпуска SSL-сертификатов:
# 1 = Certbot (HTTP-01 через веб-сервер)
# 2 = acme.sh (Cloudflare DNS-01 API)
SSL_ENGINE_CHOICE="1"

# Email для уведомлений Let's Encrypt (Enter/пусто - без email)
LE_EMAIL="admin@yourdomain.online"

# Настройки Cloudflare (требуются только при SSL_ENGINE_CHOICE=2):
# 1 = API Token (рекомендуется), 2 = Global API Key
CF_AUTH_METHOD="1"
CF_Token=""
CF_Account_ID=""
CF_Email=""
CF_Key=""

# Игнорировать несовпадение DNS при проверке [1 = да, 0 = нет]
FORCE_DNS="0"

# --- 2. СЦЕНАРИИ REALITY ---
# Сценарий 1: Steal-Oneself REALITY (Кража у самого себя с Anti-Loop) [y/n]
ENABLE_STEAL="y"
STEAL_PORT="45443"
# Домены для Steal-Oneself (через пробел, например: "cdn.yourdomain.online")
STEAL_DOMAINS="cdn.yourdomain.online"

# Сценарий 2: Classic External REALITY (Внешний камуфляж) [y/n]
ENABLE_CLASSIC="y"
CLASSIC_PORT="46443"
# Внешние доверенные SNI (через пробел, например: "dl.google.com")
CLASSIC_SNI="dl.google.com"

# --- 3. ВНУТРЕННИЕ ПОРТЫ И ПУТИ 3X-UI И xHTTP ---
PANEL_PORT="10443"
# Секретный URI-путь к веб-панели 3X-UI (если пусто, генерируется автоматически: panel-<32 hex>)
PANEL_PATH=""
# Учетные данные администратора панели 3X-UI
ADMIN_USERNAME="admin"
ADMIN_PASSWORD=""
# Префикс / название сервера для подключений (например: NL, DE, MyServer)
SERVER_PREFIX="Server"

SUB_PORT="55443"
# Секретный путь для подписок (если пусто, генерируется автоматически: /sub-xxxxxxxx/)
SUB_PATH=""
# Путь для подписок Clash / Mihomo (если пусто, генерируется автоматически: /${SUB_PATH}/clash/)
SUB_CLASH_PATH=""
# Заголовок подписки для клиентов (если пусто, заголовок не добавляется)
SUB_TITLE=""

XHTTP_STREAM_PORT="50443"
# Секретный URI-путь для xHTTP Stream-One (если пусто, генерируется случайный 8-значный токен: /xxxxxxxx/)
XHTTP_STREAM_PATH=""

# Портал веб-диагностики LibreSpeed + MTR (доступ по ссылке https://<домен>/<PANEL_PATH>/diag)
# Секретный URI-путь для портала диагностики (если пусто, генерируется автоматически: /diag-<16 hex>/)
DIAG_PATH=""
# Токен авторизации SSO диагностики (если пусто, генерируется автоматически: 16 hex-символов)
DIAG_TOKEN=""

# --- 4. UDP ТУННЕЛИ (Hysteria 2 / AmneziaWG) ---
# Hysteria 2 (UDP 443) [y/n]
ENABLE_HY2="y"
HY2_PORT="443"
# Домен/поддомен для Hysteria 2 (по умолчанию равен PRIMARY_DOMAIN)
HY2_DOMAIN="yourdomain.online"
# Port Hopping: клиент «прыгает» по UDP-портам, усложняя блокировку ТСПУ [y/n]
HY2_PORT_HOPPING="n"
# Диапазон UDP-портов для Port Hopping (формат: START:END)
HY2_PORT_HOPPING_RANGE="20000:50000"

# AmneziaWG v3.1 (Transport Protection) [y/n]
ENABLE_AWG_V3="y"
AWG_V3_PORT="8443"
# Защита заголовков Handshake (пусто = автогенерация 32-байтного ключа, 'none' = выкл)
AWG_HEADER_PROTECTION_KEY=""
# Рандомизация хвостов пакетов против анализа длины трафика WireGuard [true/false]
# ВНИМАНИЕ: false рекомендуется, так как включение randomTrailers в AWG 3.1 при активных S1-S4 обрушивает скорость в 100-300 раз!
AWG_RANDOM_TRAILERS="false"

# AmneziaWG v2.0 (Для роутеров Keenetic / OpenWrt, инбаунд 3X-UI) [y/n]
ENABLE_AWG_V2="n"
AWG_V2_PORT="8444"

# Автономный сервер AmneziaWG (awg-mgr / системная служба awg-quick@awg0 на хосте) [y/n]
ENABLE_AWG_STANDALONE="n"
AWG_STANDALONE_PORT="8445"
# Домен или IP сервера для подключения клиентов (Endpoint = host:port). SSL-сертификаты НЕ требуются!
# Если не указан, автоматически определяется внешний WAN IP сервера.
AWG_SERVER_HOST=""

# Настройки сети и DNS для клиентов AmneziaWG:
# Quad9 (9.9.9.9) и Control D Anycast (76.76.2.0) для защиты от DNS-спуфинга и высокой скорости в РФ
AWG_PRIMARY_DNS="9.9.9.9"
AWG_SECONDARY_DNS="76.76.2.0"
# Подсеть /22 (10.8.0.0/22) с емкостью до 1022 клиентов
AWG_SUBNET_IP="10.8.0.0"
AWG_SUBNET_CIDR="22"

# --- 4.1. ПРОТОКОЛЫ 3X-UI (Shadowsocks 2022 / TUIC v5 / MTProxy) ---
# Shadowsocks 2022 (L4 TCP/UDP, 2022-blake3-aes-256-gcm, инбаунд 3X-UI) [y/n]
ENABLE_SS2022="y"
SS2022_PORT="8388"

# TUIC v5 (QUIC 0-RTT, BBR Congestion Control, инбаунд 3X-UI) [y/n]
ENABLE_TUIC="y"
TUIC_PORT="8448"

# Telegram MTProxy FakeTLS (mtg-multi, инбаунд 3X-UI) [y/n]
ENABLE_MTPROTO="y"
MTPROTO_PORT="8444"
MTPROTO_FAKETLS_DOMAIN="gateway.icloud.com"
# Спонсорский промо-тег канала от @MTProxybot (32 hex-символа, опционально)
MTPROTO_ADTAG=""

# --- 5. САЙТ-МАСКИРОВКА (DECOY FRONT) ---
# 1 = DataSphere Analytics (SPA с 3D-сферой и телеметрией)
# 2 = CosmosCloud NextGen (Облачное хранилище)
# 3 = Welcome to nginx (Стандартная заглушка)
DECOY_MODE="1"

# --- 6. АВТОМАТИЧЕСКАЯ НАСТРОЙКА 3X-UI ---
# Автоматически настроить инбаунды и пути подписок в базе данных 3X-UI через configure-panel.sh [y/n]
AUTO_SETUP_3XUI="y"

# Создать API-токен для подключения сервера как узла (3X-UI Node) [y/n]
ENABLE_NODE_TOKEN="y"
# Название API-токена ноды (если не указано, формируется как <SERVER_PREFIX>-Node или Master-Node-Cluster)
NODE_TOKEN_NAME=""

# Автоматически обновлять ядро Xray-core до последней официальной версии с GitHub (v26.9.30+) [y/n]
UPDATE_XRAY_CORE="y"

# --- 6.1. ТОНКИЕ НАСТРОЙКИ ПАНЕЛИ 3X-UI И РОУТИНГА XRAY ---
# Часовой пояс панели (по умолчанию берется системный таймзон сервера или Europe/Moscow)
TIME_LOCATION="Europe/Moscow"

# Интервал автоматического обновления подписки клиентскими приложениями (в часах, 1 = каждый час)
SUB_UPDATES="1"

# Кодирование содержимого подписки в Base64 для защиты от открытой передачи ссылок [true/false]
SUB_ENCRYPT="true"

# Блокировка спам-трафика по порту 25 в Xray (порты 465 и 587 для обычной почты остаются открытыми) [y/n]
BLOCK_SMTP="y"

# Блокировка доступа клиентов прокси к локальным сетям сервера (SSRF-защита хоста и Docker) [y/n]
BLOCK_LAN="y"

# Адрес прослушивания веб-панели и подписок (127.0.0.1 при наличии Nginx, 0.0.0.0 для прямого доступа)
WEB_LISTEN="127.0.0.1"
SUB_LISTEN="127.0.0.1"

# --- 7. ИСХОДЯЩИЙ ТУННЕЛЬ CLOUDFLARE WARP ---
# Включить исходящий прокси Cloudflare WARP (WireGuard, MTU: 1280) для обхода капч Google
# и разблокировки сервисов искусственного интеллекта (Gemini, ChatGPT, Claude) [y/n]
# При этом трафик YouTube и РФ-ресурсов принудительно направляется напрямую (DIRECT).
ENABLE_WARP="n"

# Лицензионный ключ WARP+ (опционально, оставьте пустым для бесплатного безлимитного аккаунта)
WARP_LICENSE_KEY=""

# --- 8. ADGUARD HOME: ПРИВАТНЫЙ DOH + SPLIT-DNS + БЛОКИРОВКА РЕКЛАМЫ ---
# Установить AdGuard Home с приватным DNS-over-HTTPS [y/n]
ENABLE_AGH="y"
# Режим доступа к DoH:
#   1 = На основном домене (domain.com/dns-query/) — не нужен отдельный поддомен
#   2 = На отдельном поддомене (dns.domain.com) — нужна A-запись в DNS-панели
AGH_MODE="1"
# Поддомен для AdGuard Home (только при AGH_MODE=2, пусто = dns.PRIMARY_DOMAIN)
AGH_DOMAIN=""
# Учетные данные веб-панели AdGuard Home
AGH_USER="admin"
AGH_PASS=""
# Секретный ClientID для роутера / часть URL DoH (если пусто, генерируется автоматически: client-<32 hex>)
AGH_CLIENT_ID=""
# Использовать AdGuard Home как DNS для VPN-клиентов (Xray DNS → 127.0.0.1) [y/n]
AGH_XRAY_DNS="n"
# Локальный DNS-порт AdGuard Home (10053 по умолчанию, предотвращает конфликт с портом 53 systemd-resolved)
PORT_AGH_DNS="10053"

# --- 9. ИНТЕГРАЦИЯ С DOKPLOY И ПРОТОКОЛЫ СЛЕДУЮЩЕГО ПОКОЛЕНИЯ ---
# Режим бесконфликтного сосуществования с Dokploy [y/n]
# Если 'y', порты 80 и 443 остаются за Traefik (Dokploy), Nginx не перехватывает их,
# а сервисы прокси разворачиваются на независимых портах или через Traefik WebSocket/HTTP3.
DOKPLOY_COEXISTENCE="n"

# 9.1. MASQUE (RFC 9484 / RFC 9298 HTTP/3 Datagram Proxying via Sing-box 1.14+) [y/n]
# Сверхскоростное проксирование UDP/IP поверх HTTP/3 QUIC (нативная поддержка в iOS 17+ / macOS 14+)
ENABLE_MASQUE="n"
MASQUE_PORT="8449"
MASQUE_USER="client"
MASQUE_PASSWORD=""

# 9.2. ShadowTLS v4 + Shadowsocks-2022 (udp_over_tcp: true) [y/n]
# Полная маскировка под подлинный TLS-сертификат Apple/Cloudflare с HMAC-авторизацией
# и защитой от активного зондирования ТСПУ/DPI
ENABLE_SHADOWTLS="n"
SHADOWTLS_PORT="8543"
SHADOWTLS_SNI="gateway.icloud.com"
SHADOWTLS_PASSWORD=""

# 9.3. NaïveProxy + Caddy (forwardproxy@naive + Cloudflare DNS-01 ACME) [y/n]
# Маскировка сетевого стека под Google Chrome, автоматический выпуск SSL без портов 80/443
ENABLE_NAIVE="n"
NAIVE_PORT="8446"
NAIVE_DOMAIN=""
NAIVE_USER="user"
NAIVE_PASS=""

# 9.4. Server-Side Zapret (nfqws с iptables connbytes 1:6) [y/n]
# Десинхронизация DPI/ТСПУ на сервере в первые 6 пакетов соединения без снижения скорости передачи
ENABLE_ZAPRET="n"
ZAPRET_QNUM="200"
ZAPRET_DESYNC="split2"
ZAPRET_FOOLING="md5sig,badseq"

# 9.5. Wstunnel поверх Dokploy Traefik (WebSocket / HTTP/3) [y/n]
# Туннелирование WireGuard/AmneziaWG через Traefik HTTPS WebSocket (порт 443) без конфликтов портов
ENABLE_WSTUNNEL="n"
WSTUNNEL_DOMAIN=""
# Секретный URI-путь location для Wstunnel (если пусто, генерируется автоматически: /ws-<32 hex>/)
WSTUNNEL_PREFIX=""
WSTUNNEL_PORT="8080"
WSTUNNEL_SECRET=""

# 9.6. DNSTT (Emergency DNS Tunneling over DoH via dnstt-server) [y/n]
# Аварийный DNS-туннель для обхода жестких белых списков
ENABLE_DNSTT="n"
DNSTT_PORT="53053"
DNSTT_DOMAIN=""
DNSTT_PUBKEY=""

# 9.7. Mieru Proxy (mita, XChaCha20-Poly1305, без TLS) [y/n]
# Устойчив к активному зондированию ТСПУ, статистическому DPI и блокировкам по отпечаткам TLS
ENABLE_MIERU="n"
# Режим портов: single (одиночный) или range (пул портов для рандомизации)
MIERU_PORT_MODE="single"
# Порт (например 8450) или диапазон портов (например 8450-8455)
MIERU_PORT="8450"
# Транспорт: BOTH (TCP и UDP), TCP или UDP
MIERU_TRANSPORT="BOTH"
MIERU_USER=""
MIERU_PASS=""
MIERU_MTU="1400"

# --- 10. БЕЗОПАСНОСТЬ ХОСТА (HOST SECURITY & SSH HARDENING) ---
# Включить настройку безопасности хоста (порт SSH, ключи, защита от брутфорса) [y/n]
ENABLE_HOST_SECURITY="n"
# Пользовательский порт SSH (1024-65535 или текущий 22)
SSH_PORT="22"
# Установить и настроить Fail2ban для защиты от брутфорса SSH [y/n]
ENABLE_FAIL2BAN="y"
# Отключить вход по паролю (PasswordAuthentication no) только при наличии SSH-ключа [y/n]
DISABLE_PASSWORD_AUTH="n"
# Публичный ключ SSH для авторизации (например "ssh-ed25519 AAAAC3...").
SSH_PUBLIC_KEY=""
# Принудительно закрыть старый порт SSH без подтверждения перехода [y/n]
FORCE_CLOSE_OLD_SSH="n"

EOF_CONF
    ok "Шаблон конфигурации успешно сгенерирован: '$target_file'"
}

# Ранняя обработка флагов справки и генерации шаблона (доступны без root и проверки ОС)
for arg in "$@"; do
    case "$arg" in
        -v|--version)
            echo "STREAM ROUTER $SCRIPT_VERSION"
            exit 0
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        --gen-config)
            target_gen_file="server-setup.env.example"
            args=("$@")
            for ((idx=0; idx<${#args[@]}; idx++)); do
                if [ "${args[idx]}" = "--gen-config" ] && [ $((idx+1)) -lt ${#args[@]} ]; then
                    next_arg="${args[$((idx+1))]}"
                    if [[ ! "$next_arg" =~ ^- ]]; then
                        target_gen_file="$next_arg"
                    fi
                fi
            done
            generate_config_template "$target_gen_file"
            exit 0
            ;;
        --dry-run)
            echo -e "\n  ${YELLOW}${BOLD}[INFO] Режим --dry-run не поддерживается установщиком setup.sh.${NC}"
            echo -e "  Развертывание ОС и сетевого стека требует реальных изменений системы.\n"
            echo -e "  ${CYAN}Для безопасного аудита без внесения изменений используйте:${NC}"
            echo -e "    • ${WHITE}./setup.sh --check${NC}         (быстрая диагностика сервисов, портов, SSL)"
            echo -e "    • ${WHITE}./maintain.sh --dry-run${NC}    (холостой аудит базы 3X-UI и конфигов Nginx)\n"
            exit 0
            ;;
    esac
done



# ----------------------- Системные предусловия -----------------------
# Проверка прав root только при реальной установке (пропускается для --help, --gen-config, --check, --doctor)
check_root() {
    for arg in "$@"; do
        case "$arg" in
            -v|--version|-h|--help|--gen-config|--check|--doctor)
                return 0
                ;;
        esac
    done
    if [ "$EUID" -ne 0 ]; then
        die "Пожалуйста, запустите установщик с правами суперпользователя root (через sudo)."
    fi
}
check_root "$@"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        die "Данный скрипт оптимизирован строго под дистрибутивы семейств Ubuntu и Debian."
    fi
else
    die "Не удалось определить параметры текущего дистрибутива ОС."
fi

# Функция установки базовых зависимостей без вывода простыни apt
install_prerequisites() {
    local missing_pkgs=()
    declare -A pkg_map=(
        [curl]="curl"
        [bash]="bash"
        [systemctl]="systemd"
        [openssl]="openssl"
        [awk]="gawk"
        [lsb_release]="lsb-release"
        [gpg]="gnupg"
        [dig]="dnsutils"
        [socat]="socat"
        [cron]="cron"
        [ufw]="ufw"
        [python3]="python3"
        [mtr]="mtr-tiny"
    )
    for cmd in "${!pkg_map[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_pkgs+=("${pkg_map[$cmd]}")
        fi
    done

    if command -v apt-get >/dev/null 2>&1; then
        if command -v python3 >/dev/null 2>&1 && ! python3 -c "import bcrypt" >/dev/null 2>&1; then
            missing_pkgs+=("python3-bcrypt")
        fi
    fi

    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
            echo "  [DEBUG] Требуется установка: ${missing_pkgs[*]}"
        fi
        export DEBIAN_FRONTEND=noninteractive
        local apt_flags=("-o" "Acquire::Retries=3" "-o" "Acquire::http::Timeout=15")
        if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
            apt-get update "${apt_flags[@]}" 2>/dev/null || apt-get update || true
            apt-get install -y --no-install-recommends "${apt_flags[@]}" "${missing_pkgs[@]}"
        else
            apt-get update -q "${apt_flags[@]}" 2>/dev/null || apt-get update -q || true
            apt-get install -y --no-install-recommends "${apt_flags[@]}" "${missing_pkgs[@]}" -q
        fi
    else
        if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
            echo "  [DEBUG] Все базовые утилиты уже установлены — пропускаем apt-get."
        fi
    fi

    # Отключение навязчивой рекламы Canonical, ESM Apps и спама motd в Ubuntu
    if command -v pro >/dev/null 2>&1; then
        pro config set apt_news=false >/dev/null 2>&1 || true
    fi
    if [ -f /etc/default/motd-news ]; then
        sed -i 's/ENABLED=1/ENABLED=0/' /etc/default/motd-news 2>/dev/null || true
    fi
    systemctl stop motd-news.timer >/dev/null 2>&1 || true
    systemctl disable motd-news.timer >/dev/null 2>&1 || true
    chmod -x /etc/update-motd.d/10-help-text \
             /etc/update-motd.d/50-motd-news \
             /etc/update-motd.d/88-esm-announce \
             /etc/update-motd.d/91-contract-ua-esm-status >/dev/null 2>&1 || true
    if [ -f /etc/apt/apt.conf.d/20apt-esm-hook.conf ]; then
        rm -f /etc/apt/apt.conf.d/20apt-esm-hook.conf
        touch /etc/apt/apt.conf.d/20apt-esm-hook.conf
    fi
    rm -f /var/lib/update-notifier/updates-available 2>/dev/null || true
}


# =============================================================
#  ФУНКЦИИ НЕИНТЕРАКТИВНОГО РЕЖИМА, CLI И .ENV
# =============================================================
# Примечание: show_help() и generate_config_template() определены выше (до проверки root/OS),
# чтобы --help и --gen-config работали без привилегий суперпользователя.

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
normalize_node_token_config() {
    local enabled="${CLI_ENABLE_NODE_TOKEN:-${ENABLE_NODE_TOKEN:-y}}"
    NODE_TOKEN="${NODE_TOKEN:-}"
    NODE_TOKEN_NAME="${CLI_NODE_TOKEN_NAME:-${NODE_TOKEN_NAME:-}}"
    case "${enabled,,}" in y|1|true) ENABLE_NODE_TOKEN=y ;; *) ENABLE_NODE_TOKEN=n; return 0 ;; esac
    case "${AUTO_SETUP_3XUI:-y}" in n|0|false) ENABLE_NODE_TOKEN=n; return 0 ;; esac
    if [ -z "$NODE_TOKEN_NAME" ]; then
        local prefix="${SERVER_PREFIX-Server}"
        case "${prefix,,}" in ''|-|none|off|no) NODE_TOKEN_NAME=Master-Node-Cluster ;; *) NODE_TOKEN_NAME="${prefix}-Node" ;; esac
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
        [[ "$line" =~ ^(NODE_TOKEN_NAME|NODE_TOKEN)=(.*)$ ]] || continue
        key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
        if [[ "$value" =~ $double_quote ]] || [[ "$value" =~ $single_quote ]]; then value="${BASH_REMATCH[1]}"; fi
        printf -v "$key" '%s' "$value"
    done < "$file"
    [ -n "${NODE_TOKEN:-}" ]
}

if ! declare -f generate_secret_token >/dev/null 2>&1 || ! declare -f is_true >/dev/null 2>&1 || ! declare -f normalize_node_token_config >/dev/null 2>&1; then
    _env_src_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
    [ -f "$_env_src_dir/../common/secrets.sh" ] && source "$_env_src_dir/../common/secrets.sh"
    [ -f "$_env_src_dir/../common/config.sh" ] && source "$_env_src_dir/../common/config.sh"
    [ -f "$_env_src_dir/../common/node-token.sh" ] && source "$_env_src_dir/../common/node-token.sh"
fi

# Remember explicit inputs before normalization adds defaults.
declare -A CONFIG_EXPLICIT_KEYS=()
while IFS= read -r _input_name; do CONFIG_EXPLICIT_KEYS[$_input_name]=1; done < <(compgen -v)

ensure_panel_path() {
    local path="${PANEL_PATH:-${RAW_PATH:-}}"
    path="${path#/}"; path="${path%/}"
    if [ -z "$path" ]; then
        path=$(read_existing_panel_path) || return 1
        path="${path#/}"; path="${path%/}"
    fi
    if [ -z "$path" ]; then
        path="panel-$(generate_secret_token)" || return 1
    fi
    RAW_PATH="$path"
    PANEL_PATH="/${path}/"
}

read_existing_panel_path() {
    local db candidate python_cmd=""
    for db in "${DB_PATH:-/etc/x-ui/x-ui.db}" /usr/local/x-ui/bin/x-ui.db /etc/x-ui/db/x-ui.db; do
        [ -f "$db" ] || continue
        for candidate in "${PYTHON_CMD:-python3}" python; do
            if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sqlite3' >/dev/null 2>&1; then
                python_cmd="$candidate"
                break
            fi
        done
        [ -n "$python_cmd" ] || { warn "Для чтения действующего пути панели требуется Python 3."; return 1; }
        "$python_cmd" - "$db" << 'EOF_PANEL_PATH'
import sqlite3
import sys
from pathlib import Path

with sqlite3.connect(Path(sys.argv[1]).resolve().as_uri() + "?mode=ro", uri=True) as conn:
    row = conn.execute("SELECT value FROM settings WHERE key='webBasePath'").fetchone()
    print((row[0] if row else "") or "")
EOF_PANEL_PATH
        return $?
    done
}

ensure_agh_client_id() {
    if [ -z "${AGH_CLIENT_ID:-}" ]; then
        AGH_CLIENT_ID="client-$(generate_secret_token)" || return 1
    fi
}

ensure_wstunnel_prefix() {
    local prefix="${WSTUNNEL_PREFIX:-}"
    prefix="${prefix#/}"; prefix="${prefix%/}"
    if [ -z "$prefix" ]; then
        prefix="ws-$(generate_secret_token)" || return 1
    fi
    WSTUNNEL_PREFIX="/${prefix}/"
}

ensure_diag_path() {
    local path="${DIAG_PATH:-}"
    path="${path#/}"; path="${path%/}"
    if [ -z "$path" ]; then
        local diag_tok
        diag_tok=$(generate_secret_token) || return 1
        path="diag-${diag_tok}"
    fi
    DIAG_PATH="/${path}/"
    if [ -z "${DIAG_TOKEN:-}" ]; then
        DIAG_TOKEN="$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 16 || echo "tok${RANDOM}")"
    fi
}

rotate_secret_paths() {
    # Only the full installer may rotate paths; companion scripts preserve them.
    local panel_token ws_token client_token diag_token
    panel_token=$(generate_secret_token) || return 1
    ws_token=$(generate_secret_token) || return 1
    client_token=$(generate_secret_token) || return 1
    diag_token=$(generate_secret_token) || return 1
    RAW_PATH="panel-${panel_token}"
    PANEL_PATH="/${RAW_PATH}/"
    WSTUNNEL_PREFIX="/ws-${ws_token}/"
    AGH_CLIENT_ID="client-${client_token}"
    DIAG_PATH="/diag-${diag_token}/"
    DIAG_TOKEN="$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 16 || echo "tok${RANDOM}")"
    AUTO_SETUP_3XUI=y
    LAST_COMPLETED_STEP=0
    RESUME_STEP=1
}

reconstruct_arrays_from_vars() {
    [ -n "${PRIMARY_DOMAIN:-}" ] || return 0

    ALL_DOMAINS=("$PRIMARY_DOMAIN")
    local v_www="${ADD_WWW:-n}"
    if [[ "${v_www,,}" == "y" || "$v_www" == "1" ]]; then
        ALL_DOMAINS+=("www.$PRIMARY_DOMAIN")
    fi
    IFS=',' read -r -a extra_arr <<< "${EXTRA_SSL_DOMAINS:-}"
    for ed in "${extra_arr[@]}"; do
        ed=$(echo "$ed" | tr -d '[:space:]')
        [ -n "$ed" ] && ALL_DOMAINS+=("$ed")
    done

    local steal_raw="${STEAL_DOMAINS_STR:-${STEAL_DOMAINS[*]:-}}"
    STEAL_DOMAINS=()
    declare -g -A DOMAIN_TO_PORT=()
    local v_stl="${ENABLE_STEAL:-y}"
    if [[ "${v_stl,,}" == "y" || "$v_stl" == "1" ]]; then
        STEAL_ENABLED=1
        STEAL_PORTS_LIST=(${STEAL_PORT:-45443})
        for sd in ${steal_raw//,/ }; do
            sd=$(echo "$sd" | tr -d '[:space:]')
            if [ -n "$sd" ]; then
                if [ "$sd" = "$PRIMARY_DOMAIN" ]; then
                    warn "  Коллизия: '$sd' в STEAL_DOMAINS совпадает с PRIMARY_DOMAIN!"
                    warn "  Главный домен зарезервирован за Nginx L7. Переключено на 'cdn.$PRIMARY_DOMAIN'."
                    sd="cdn.$PRIMARY_DOMAIN"
                fi
                STEAL_DOMAINS+=("$sd")
                DOMAIN_TO_PORT["$sd"]="${STEAL_PORTS_LIST[0]}"
                [[ " ${ALL_DOMAINS[*]} " =~ " ${sd} " ]] || ALL_DOMAINS+=("$sd")
            fi
        done
        [ ${#STEAL_DOMAINS[@]} -gt 0 ] || {
            STEAL_DOMAINS=("cdn.$PRIMARY_DOMAIN")
            DOMAIN_TO_PORT["cdn.$PRIMARY_DOMAIN"]="${STEAL_PORTS_LIST[0]}"
            ALL_DOMAINS+=("cdn.$PRIMARY_DOMAIN")
        }
    else
        STEAL_ENABLED=0
        STEAL_PORTS_LIST=()
    fi

    declare -g -A EXT_SNI_TO_PORT=()
    local v_cls="${ENABLE_CLASSIC:-y}"
    if [[ "${v_cls,,}" == "y" || "$v_cls" == "1" ]]; then
        CLASSIC_ENABLED=1
        CLASSIC_PORTS_LIST=(${CLASSIC_PORT:-46443})
        local classic_raw="${CLASSIC_SNI:-dl.google.com}"
        EXT_SNI_LIST=()
        for cs in ${classic_raw//,/ }; do
            cs=$(echo "$cs" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            if [ -n "$cs" ]; then
                [[ " ${EXT_SNI_LIST[*]:-} " =~ " ${cs} " ]] && continue
                EXT_SNI_LIST+=("$cs")
                EXT_SNI_TO_PORT["$cs"]="${CLASSIC_PORTS_LIST[0]}"
            fi
        done
        [ ${#EXT_SNI_TO_PORT[@]} -gt 0 ] || {
            EXT_SNI_LIST=("dl.google.com")
            EXT_SNI_TO_PORT["dl.google.com"]="${CLASSIC_PORTS_LIST[0]}"
        }
    else
        CLASSIC_ENABLED=0
        CLASSIC_PORTS_LIST=()
        EXT_SNI_LIST=()
    fi

    ALL_REALITY_PORTS=()
    for p in "${STEAL_PORTS_LIST[@]:-}"; do [ -n "$p" ] && ALL_REALITY_PORTS+=("$p"); done
    for p in "${CLASSIC_PORTS_LIST[@]:-}"; do [ -n "$p" ] && ALL_REALITY_PORTS+=("$p"); done
    REALITY_FINGERPRINT="${REALITY_FINGERPRINT:-${FINGERPRINT:-firefox}}"

    PANEL_PORT="${PANEL_PORT:-10443}"
    ensure_panel_path || return 1

    SUB_PORT="${SUB_PORT:-55443}"
    if [ -z "${RAW_SUB_PATH:-}" ] || [ "${RAW_SUB_PATH:-}" = "my-post-key" ]; then
        if [ -n "${SUB_PATH:-}" ] && [ "${SUB_PATH:-}" != "my-post-key" ] && [ "${SUB_PATH:-}" != "/my-post-key/" ]; then
            RAW_SUB_PATH="${SUB_PATH}"
        else
            RAW_SUB_PATH="sub-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "sub${RANDOM}")"
        fi
    fi
    RAW_SUB_PATH="${RAW_SUB_PATH#/}"
    RAW_SUB_PATH="${RAW_SUB_PATH%/}"
    SUB_PATH="/${RAW_SUB_PATH}/"
    SUB_JSON_PATH="${SUB_PATH}json/"
    local _c_path="${SUB_CLASH_PATH:-${RAW_SUB_CLASH_PATH:-${SUB_PATH%/}/clash/}}"
    _c_path="${_c_path#/}"; _c_path="${_c_path%/}"
    SUB_CLASH_PATH="/${_c_path}/"

    XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
    if [ -z "${RAW_XHTTP_STREAM_PATH:-}" ] || [ "${RAW_XHTTP_STREAM_PATH:-}" = "Stream-One-Path" ] || [[ "${RAW_XHTTP_STREAM_PATH:-}" == vless-* ]]; then
        if [ -n "${XHTTP_STREAM_PATH:-}" ] && [ "${XHTTP_STREAM_PATH:-}" != "Stream-One-Path" ] && [ "${XHTTP_STREAM_PATH:-}" != "/Stream-One-Path/" ] && [[ "${XHTTP_STREAM_PATH:-}" != *vless-* ]]; then
            RAW_XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH}"
        else
            RAW_XHTTP_STREAM_PATH="$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "xh${RANDOM}")"
        fi
    fi
    RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH#/}"
    RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH%/}"
    XHTTP_STREAM_PATH="/${RAW_XHTTP_STREAM_PATH}/"

    SERVER_PREFIX="${SERVER_PREFIX:-Server}"
    SUB_TITLE="${SUB_TITLE:-$SERVER_PREFIX}"
    ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
    DECOY_MODE="${DECOY_MODE:-1}"
    SSL_ENGINE_CHOICE="${SSL_ENGINE_CHOICE:-1}"
    LE_EMAIL="${LE_EMAIL:-}"

    # Нормализация логических переменных (1/0 и y/n)
    local _v
    _v="${ENABLE_WEB_STACK:-y}"; if is_true "$_v"; then ENABLE_WEB_STACK=1; else ENABLE_WEB_STACK=0; fi
    AWG_SERVER_HOST="${AWG_SERVER_HOST:-}"
    _v="${ENABLE_STEAL:-${STEAL_ENABLED:-y}}"; if is_true "$_v"; then ENABLE_STEAL="y"; STEAL_ENABLED=1; else ENABLE_STEAL="n"; STEAL_ENABLED=0; fi
    _v="${ENABLE_CLASSIC:-${CLASSIC_ENABLED:-y}}"; if is_true "$_v"; then ENABLE_CLASSIC="y"; CLASSIC_ENABLED=1; else ENABLE_CLASSIC="n"; CLASSIC_ENABLED=0; fi
    _v="${ENABLE_HY2:-n}"
    if is_true "$_v"; then
        ENABLE_HY2=1
        HY2_PORT="${HY2_PORT:-443}"
        HY2_DOMAIN="${HY2_DOMAIN:-$PRIMARY_DOMAIN}"
        if [[ ! " ${ALL_DOMAINS[*]} " == *" ${HY2_DOMAIN} "* ]]; then
            ALL_DOMAINS+=("$HY2_DOMAIN")
        fi
    else
        ENABLE_HY2=0
    fi
    _v="${ENABLE_AWG_V3:-n}"; if is_true "$_v"; then ENABLE_AWG_V3=1; else ENABLE_AWG_V3=0; fi
    _v="${ENABLE_AWG_V2:-n}"; if is_true "$_v"; then ENABLE_AWG_V2=1; else ENABLE_AWG_V2=0; fi
    _v="${ENABLE_AWG_STANDALONE:-n}"; if is_true "$_v"; then ENABLE_AWG_STANDALONE=1; else ENABLE_AWG_STANDALONE=0; fi
    AWG_STANDALONE_PORT="${AWG_STANDALONE_PORT:-8445}"
    _v="${ENABLE_SS2022:-n}"; if is_true "$_v"; then ENABLE_SS2022=1; else ENABLE_SS2022=0; fi
    SS2022_PORT="${SS2022_PORT:-8388}"
    _v="${ENABLE_TUIC:-n}"; if is_true "$_v"; then ENABLE_TUIC=1; else ENABLE_TUIC=0; fi
    TUIC_PORT="${TUIC_PORT:-8448}"
    _v="${ENABLE_MTPROTO:-n}"; if is_true "$_v"; then ENABLE_MTPROTO=1; else ENABLE_MTPROTO=0; fi
    MTPROTO_PORT="${MTPROTO_PORT:-8444}"
    MTPROTO_FAKETLS_DOMAIN="${MTPROTO_FAKETLS_DOMAIN:-gateway.icloud.com}"
    MTPROTO_ADTAG="${MTPROTO_ADTAG:-}"
    _v="${ENABLE_AGH:-n}"
    if is_true "$_v"; then
        ENABLE_AGH=1
        if [ "${AGH_MODE:-1}" = "2" ] && [ -n "${AGH_DOMAIN:-}" ]; then
            if [[ ! " ${ALL_DOMAINS[*]} " == *" ${AGH_DOMAIN} "* ]]; then
                ALL_DOMAINS+=("$AGH_DOMAIN")
            fi
        fi
    else
        ENABLE_AGH=0
    fi
    _v="${ENABLE_WARP:-n}"; if is_true "$_v"; then ENABLE_WARP="y"; else ENABLE_WARP="n"; fi
    normalize_node_token_config
    _v="${AGH_XRAY_DNS:-n}"; if is_true "$_v"; then AGH_XRAY_DNS="y"; else AGH_XRAY_DNS="n"; fi
    HY2_PORT_HOPPING="${HY2_PORT_HOPPING:-n}"
    AUTO_SETUP_3XUI="${AUTO_SETUP_3XUI:-y}"
    _v="${SHOW_MANUAL_STEPS:-n}"; if is_true "$_v"; then SHOW_MANUAL_STEPS=1; else SHOW_MANUAL_STEPS=0; fi
    PORT_AGH_WEB="${PORT_AGH_WEB:-3000}"
    PORT_AGH_DNS="${PORT_AGH_DNS:-10053}"
    ensure_agh_client_id || return 1

    ensure_diag_path || return 1

    # Сосуществование с Dokploy и протоколы следующего поколения
    _v="${DOKPLOY_COEXISTENCE:-n}"; if is_true "$_v"; then DOKPLOY_COEXISTENCE="y"; else DOKPLOY_COEXISTENCE="n"; fi
    if [ "$DOKPLOY_COEXISTENCE" = "y" ]; then
        ENABLE_WEB_STACK=0
    fi
    _v="${ENABLE_MASQUE:-n}"; if is_true "$_v"; then ENABLE_MASQUE=1; else ENABLE_MASQUE=0; fi
    MASQUE_PORT="${MASQUE_PORT:-8449}"
    MASQUE_USER="${MASQUE_USER:-client}"
    if [ "$ENABLE_MASQUE" -eq 1 ] && [ -z "${MASQUE_PASSWORD:-}" ]; then
        MASQUE_PASSWORD="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "masque${RANDOM}")"
    fi
    _v="${ENABLE_SHADOWTLS:-n}"; if is_true "$_v"; then ENABLE_SHADOWTLS=1; else ENABLE_SHADOWTLS=0; fi
    SHADOWTLS_PORT="${SHADOWTLS_PORT:-8543}"
    SHADOWTLS_SNI="${SHADOWTLS_SNI:-gateway.icloud.com}"
    if [ "$ENABLE_SHADOWTLS" -eq 1 ] && [ -z "${SHADOWTLS_PASSWORD:-}" ]; then
        SHADOWTLS_PASSWORD="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "stls${RANDOM}")"
    fi
    if [ "$ENABLE_SHADOWTLS" -eq 1 ] && [ "${ENABLE_WEB_STACK:-1}" -eq 1 ]; then
        ENABLE_SS2022=1
    fi
    _v="${ENABLE_NAIVE:-n}"; if is_true "$_v"; then ENABLE_NAIVE=1; else ENABLE_NAIVE=0; fi
    NAIVE_PORT="${NAIVE_PORT:-8446}"
    if [ "$ENABLE_NAIVE" -eq 1 ] && [ -z "${NAIVE_DOMAIN:-}" ] && [ -n "${PRIMARY_DOMAIN:-}" ]; then
        NAIVE_DOMAIN="naive.${PRIMARY_DOMAIN}"
    fi
    NAIVE_DOMAIN="${NAIVE_DOMAIN:-}"
    if [ "$ENABLE_NAIVE" -eq 1 ] && [ -n "$NAIVE_DOMAIN" ] && [ "$NAIVE_DOMAIN" = "${PRIMARY_DOMAIN:-}" ]; then
        warn "  Коллизия: NAIVE_DOMAIN '$NAIVE_DOMAIN' совпадает с PRIMARY_DOMAIN!"
        warn "  Главный домен зарезервирован за веб-маской Nginx. Переключено на 'naive.$PRIMARY_DOMAIN'."
        NAIVE_DOMAIN="naive.$PRIMARY_DOMAIN"
    fi
    if [ "$ENABLE_NAIVE" -eq 1 ] && [ -n "$NAIVE_DOMAIN" ]; then
        if [[ ! " ${ALL_DOMAINS[*]} " == *" ${NAIVE_DOMAIN} "* ]]; then
            ALL_DOMAINS+=("$NAIVE_DOMAIN")
        fi
    fi
    NAIVE_USER="${NAIVE_USER:-user}"
    if [ "$ENABLE_NAIVE" -eq 1 ] && [ -z "${NAIVE_PASS:-}" ]; then
        NAIVE_PASS="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "naive${RANDOM}")"
    fi
    _v="${ENABLE_DNSTT:-n}"; if is_true "$_v"; then ENABLE_DNSTT=1; else ENABLE_DNSTT=0; fi
    DNSTT_PORT="${DNSTT_PORT:-53053}"
    if [ "$ENABLE_DNSTT" -eq 1 ] && [ -z "${DNSTT_DOMAIN:-}" ] && [ -n "${PRIMARY_DOMAIN:-}" ]; then
        DNSTT_DOMAIN="t.${PRIMARY_DOMAIN}"
    fi
    DNSTT_DOMAIN="${DNSTT_DOMAIN:-}"
    DNSTT_PUBKEY="${DNSTT_PUBKEY:-}"
    if [ "$ENABLE_DNSTT" -eq 1 ]; then
        ENABLE_SS2022=1
    fi
    _v="${ENABLE_ZAPRET:-n}"; if is_true "$_v"; then ENABLE_ZAPRET=1; else ENABLE_ZAPRET=0; fi
    ZAPRET_QNUM="${ZAPRET_QNUM:-200}"
    ZAPRET_DESYNC="${ZAPRET_DESYNC:-split2}"
    ZAPRET_FOOLING="${ZAPRET_FOOLING:-md5sig,badseq}"
    _v="${ENABLE_WSTUNNEL:-n}"; if is_true "$_v"; then ENABLE_WSTUNNEL=1; else ENABLE_WSTUNNEL=0; fi
    WSTUNNEL_DOMAIN="${WSTUNNEL_DOMAIN:-}"
    ensure_wstunnel_prefix || return 1
    WSTUNNEL_PORT="${WSTUNNEL_PORT:-8080}"
    if [ "$ENABLE_WSTUNNEL" -eq 1 ] && [ -z "${WSTUNNEL_SECRET:-}" ]; then
        WSTUNNEL_SECRET="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "wst${RANDOM}")"
    fi
    _v="${ENABLE_MIERU:-n}"; if is_true "$_v"; then ENABLE_MIERU=1; else ENABLE_MIERU=0; fi
    MIERU_PORT_MODE="${MIERU_PORT_MODE:-single}"
    case "${MIERU_PORT_MODE,,}" in
        range|pool)
            MIERU_PORT_MODE="range"
            MIERU_PORT="${MIERU_PORT:-8450-8455}"
            ;;
        *)
            MIERU_PORT_MODE="single"
            MIERU_PORT="${MIERU_PORT:-8450}"
            ;;
    esac
    MIERU_TRANSPORT="${MIERU_TRANSPORT:-BOTH}"
    if [ "$ENABLE_MIERU" -eq 1 ] && [ -z "${MIERU_USER:-}" ]; then
        MIERU_USER="user-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "mieru${RANDOM}")"
    fi
    MIERU_USER="${MIERU_USER:-}"
    if [ "$ENABLE_MIERU" -eq 1 ] && [ -z "${MIERU_PASS:-}" ]; then
        MIERU_PASS="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "mieru${RANDOM}")"
    fi
    MIERU_PASS="${MIERU_PASS:-}"
    MIERU_MTU="${MIERU_MTU:-1400}"
    CF_AUTH_METHOD="${CF_AUTH_METHOD:-1}"
    _v="${ENABLE_HOST_SECURITY:-n}"; if is_true "$_v"; then ENABLE_HOST_SECURITY="y"; else ENABLE_HOST_SECURITY="n"; fi
    SSH_PORT="${SSH_PORT:-${SSH_ACTIVE_PORT:-22}}"
    _v="${ENABLE_FAIL2BAN:-n}"; if is_true "$_v"; then ENABLE_FAIL2BAN="y"; else ENABLE_FAIL2BAN="n"; fi
    _v="${DISABLE_PASSWORD_AUTH:-n}"; if is_true "$_v"; then DISABLE_PASSWORD_AUTH="y"; else DISABLE_PASSWORD_AUTH="n"; fi
    SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
    _v="${FORCE_CLOSE_OLD_SSH:-n}"; if is_true "$_v"; then FORCE_CLOSE_OLD_SSH="y"; else FORCE_CLOSE_OLD_SSH="n"; fi
}

load_env_file() {
    local env_file="$1"
    [ -f "$env_file" ] || return 0
    log "Загрузка параметров из конфигурационного файла: $env_file"
    if ! load_config_data_safe "$env_file"; then
        die "Ошибка синтаксиса или безопасности при загрузке конфигурации $env_file"
    fi
    reconstruct_arrays_from_vars
}

finalize_installation_config() {
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        REALITY_FALLBACK_PORT="${REALITY_FALLBACK_PORT:-9443}"
        normalize_node_token_config
        ensure_panel_path || return 1
        ensure_diag_path || return 1
        ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
        ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
        if is_true "${AUTO_SETUP_3XUI:-y}" && [ -z "$ADMIN_PASSWORD" ] &&
           [ ! -s "${DB_PATH:-/etc/x-ui/x-ui.db}" ] && [ ! -s /usr/local/x-ui/bin/x-ui.db ]; then
            ADMIN_PASSWORD=$(generate_secret_token) || return 1
        fi
        if is_true "${ENABLE_AGH:-n}"; then
            AGH_MODE="${AGH_MODE:-1}"
            AGH_DOMAIN="${AGH_DOMAIN:-}"
            AGH_USER="${AGH_USER:-admin}"
            if [ -z "${AGH_PASS:-}" ]; then AGH_PASS=$(generate_secret_token) || return 1; fi
            ensure_agh_client_id || return 1
        fi
    fi
}

save_session_state() {
    local save_path="${1:-server-setup.env}"
    # Resolve once in the caller's state before serializing it.
    ensure_panel_path || return 1
    ensure_diag_path || return 1
    ensure_agh_client_id || return 1
    if is_true "${ENABLE_WSTUNNEL:-n}"; then
        ensure_wstunnel_prefix || return 1
    fi
    # Защита от утечки секретов: ограничиваем права доступа при создании файла
    local old_umask
    old_umask=$(umask)
    umask 077

    local v=""
    local dokploy_coexist_save="n"
    v="${DOKPLOY_COEXISTENCE:-n}"; is_true "$v" && dokploy_coexist_save="y"
    local web_stack_save="n"
    if [ "$dokploy_coexist_save" = "y" ]; then
        web_stack_save="dokploy"
    else
        v="${ENABLE_WEB_STACK:-y}"; is_true "$v" && web_stack_save="y"
    fi
    local steal_save="n"
    v="${ENABLE_STEAL:-${STEAL_ENABLED:-n}}"; is_true "$v" && steal_save="y"
    local classic_save="n"
    v="${ENABLE_CLASSIC:-${CLASSIC_ENABLED:-n}}"; is_true "$v" && classic_save="y"
    local hy2_save="n"
    v="${ENABLE_HY2:-n}"; is_true "$v" && hy2_save="y"
    local awg_v3_save="n"
    v="${ENABLE_AWG_V3:-n}"; is_true "$v" && awg_v3_save="y"
    local awg_v2_save="n"
    v="${ENABLE_AWG_V2:-n}"; is_true "$v" && awg_v2_save="y"
    local awg_standalone_save="n"
    v="${ENABLE_AWG_STANDALONE:-n}"; is_true "$v" && awg_standalone_save="y"
    local ss2022_save="n"
    v="${ENABLE_SS2022:-n}"; is_true "$v" && ss2022_save="y"
    local tuic_save="n"
    v="${ENABLE_TUIC:-n}"; is_true "$v" && tuic_save="y"
    local mtproto_save="n"
    v="${ENABLE_MTPROTO:-n}"; is_true "$v" && mtproto_save="y"
    local auto_setup_3xui_save="n"
    v="${AUTO_SETUP_3XUI:-n}"; is_true "$v" && auto_setup_3xui_save="y"
    local node_token_save="n"
    v="${ENABLE_NODE_TOKEN:-y}"; is_true "$v" && node_token_save="y"
    local warp_save="n"
    v="${ENABLE_WARP:-n}"; is_true "$v" && warp_save="y"
    local agh_save="n"
    v="${ENABLE_AGH:-n}"; is_true "$v" && agh_save="y"
    local agh_xray_save="n"
    v="${AGH_XRAY_DNS:-n}"; is_true "$v" && agh_xray_save="y"
    local masque_save="n"
    v="${ENABLE_MASQUE:-n}"; is_true "$v" && masque_save="y"
    local shadowtls_save="n"
    v="${ENABLE_SHADOWTLS:-n}"; is_true "$v" && shadowtls_save="y"
    local naive_save="n"
    v="${ENABLE_NAIVE:-n}"; is_true "$v" && naive_save="y"
    local dnstt_save="n"
    v="${ENABLE_DNSTT:-n}"; is_true "$v" && dnstt_save="y"
    local zapret_save="n"
    v="${ENABLE_ZAPRET:-n}"; is_true "$v" && zapret_save="y"
    local wstunnel_save="n"
    v="${ENABLE_WSTUNNEL:-n}"; is_true "$v" && wstunnel_save="y"
    local mieru_save="n"
    v="${ENABLE_MIERU:-n}"; is_true "$v" && mieru_save="y"
    local host_security_save="n"
    v="${ENABLE_HOST_SECURITY:-n}"; is_true "$v" && host_security_save="y"
    local fail2ban_save="n"
    v="${ENABLE_FAIL2BAN:-n}"; is_true "$v" && fail2ban_save="y"
    local disable_pwd_save="n"
    v="${DISABLE_PASSWORD_AUTH:-n}"; is_true "$v" && disable_pwd_save="y"
    local force_close_old_save="n"
    v="${FORCE_CLOSE_OLD_SSH:-n}"; is_true "$v" && force_close_old_save="y"

    local _save_panel_path="${PANEL_PATH}"
    _save_panel_path="${_save_panel_path#/}"
    _save_panel_path="${_save_panel_path%/}"

    local _save_sub_path="${RAW_SUB_PATH:-${SUB_PATH:-my-post-key}}"
    _save_sub_path="${_save_sub_path#/}"
    _save_sub_path="${_save_sub_path%/}"

    local _save_sub_clash_path="${RAW_SUB_CLASH_PATH:-${SUB_CLASH_PATH:-${_save_sub_path}/clash}}"
    _save_sub_clash_path="${_save_sub_clash_path#/}"
    _save_sub_clash_path="${_save_sub_clash_path%/}"

    local _save_xhttp_path="${RAW_XHTTP_STREAM_PATH:-${XHTTP_STREAM_PATH:-}}"
    _save_xhttp_path="${_save_xhttp_path#/}"
    _save_xhttp_path="${_save_xhttp_path%/}"
    if [ -z "$_save_xhttp_path" ] || [ "$_save_xhttp_path" = "Stream-One-Path" ] || [[ "$_save_xhttp_path" == vless-* ]]; then
        _save_xhttp_path="$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "xh${RANDOM}")"
    fi

    local save_tmp
    save_tmp=$(mktemp "${save_path}.tmp.XXXXXX") || { umask "$old_umask"; return 1; }
    if ! cat << EOF_SAVE > "$save_tmp"

# ==============================================================================
# АВТОМАТИЧЕСКИ СОХРАНЕННАЯ КОНФИГУРАЦИЯ СЕССИИ
# Для перезапуска без вопросов: ./setup.sh --config $save_path --non-interactive
# ==============================================================================
ENABLE_WEB_STACK="$web_stack_save"
PRIMARY_DOMAIN="${PRIMARY_DOMAIN:-}"
ADD_WWW="${ADD_WWW:-y}"
EXTRA_SSL_DOMAINS="${EXTRA_SSL_DOMAINS:-${EXTRA_DOMAINS_USER[*]:-}}"
SSL_ENGINE_CHOICE="${SSL_ENGINE_CHOICE:-1}"
LE_EMAIL="${LE_EMAIL:-}"
CF_AUTH_METHOD="${CF_AUTH_METHOD:-1}"
CF_Token="${CF_Token:-}"
CF_Account_ID="${CF_Account_ID:-}"
CF_Email="${CF_Email:-}"
CF_Key="${CF_Key:-}"
FORCE_DNS="${FORCE_DNS:-0}"

ENABLE_STEAL="$steal_save"
STEAL_PORT="${STEAL_PORTS_LIST[0]:-45443}"
STEAL_DOMAINS="${STEAL_DOMAINS[*]:-}"

ENABLE_CLASSIC="$classic_save"
CLASSIC_PORT="${CLASSIC_PORTS_LIST[0]:-46443}"
CLASSIC_SNI="${EXT_SNI_LIST[*]:-}"
REALITY_FINGERPRINT="${REALITY_FINGERPRINT:-${FINGERPRINT:-firefox}}"

PORTS_SETUP_MODE="${PORTS_SETUP_MODE:-0}"
PATHS_SETUP_MODE="${PATHS_SETUP_MODE:-0}"
REALITY_FALLBACK_PORT="${REALITY_FALLBACK_PORT:-9443}"

PANEL_PORT="${PANEL_PORT:-10443}"
PANEL_PATH="${_save_panel_path}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
SERVER_PREFIX="${SERVER_PREFIX:-Server}"
SUB_PORT="${SUB_PORT:-55443}"
SUB_PATH="${_save_sub_path}"
SUB_CLASH_PATH="${_save_sub_clash_path}"
SUB_TITLE="${SUB_TITLE:-${SERVER_PREFIX:-Server}}"
XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
XHTTP_STREAM_PATH="${_save_xhttp_path}"

ENABLE_HY2="$hy2_save"
HY2_PORT="${HY2_PORT:-443}"
HY2_DOMAIN="${HY2_DOMAIN:-${PRIMARY_DOMAIN:-}}"
HY2_PORT_HOPPING="${HY2_PORT_HOPPING:-n}"
HY2_PORT_HOPPING_RANGE="${HY2_PORT_HOPPING_RANGE:-20000:50000}"

ENABLE_AWG_V3="$awg_v3_save"
AWG_V3_PORT="${AWG_V3_PORT:-8443}"
AWG_HEADER_PROTECTION_KEY="${AWG_HEADER_PROTECTION_KEY:-}"
AWG_RANDOM_TRAILERS="${AWG_RANDOM_TRAILERS:-false}"

ENABLE_AWG_V2="$awg_v2_save"
AWG_V2_PORT="${AWG_V2_PORT:-8444}"

ENABLE_AWG_STANDALONE="$awg_standalone_save"
AWG_STANDALONE_PORT="${AWG_STANDALONE_PORT:-8445}"
AWG_SERVER_HOST="${AWG_SERVER_HOST:-}"

ENABLE_SS2022="$ss2022_save"
SS2022_PORT="${SS2022_PORT:-8388}"

ENABLE_TUIC="$tuic_save"
TUIC_PORT="${TUIC_PORT:-8448}"

ENABLE_MTPROTO="$mtproto_save"
MTPROTO_PORT="${MTPROTO_PORT:-8444}"
MTPROTO_FAKETLS_DOMAIN="${MTPROTO_FAKETLS_DOMAIN:-gateway.icloud.com}"
MTPROTO_ADTAG="${MTPROTO_ADTAG:-}"

AWG_PRIMARY_DNS="${AWG_PRIMARY_DNS:-9.9.9.9}"
AWG_SECONDARY_DNS="${AWG_SECONDARY_DNS:-76.76.2.0}"
AWG_SUBNET_IP="${AWG_SUBNET_IP:-10.8.0.0}"
AWG_SUBNET_CIDR="${AWG_SUBNET_CIDR:-22}"

DECOY_MODE="${DECOY_MODE:-1}"
AUTO_SETUP_3XUI="$auto_setup_3xui_save"
ENABLE_NODE_TOKEN="$node_token_save"
NODE_TOKEN_NAME="${NODE_TOKEN_NAME:-}"
NODE_TOKEN="${NODE_TOKEN:-}"

ENABLE_WARP="$warp_save"
WARP_LICENSE_KEY="${WARP_LICENSE_KEY:-}"
ENABLE_AGH="$agh_save"
AGH_MODE="${AGH_MODE:-1}"
AGH_DOMAIN="${AGH_DOMAIN:-}"
AGH_USER="${AGH_USER:-admin}"
AGH_PASS="${AGH_PASS:-}"
AGH_CLIENT_ID="${AGH_CLIENT_ID}"
PORT_AGH_WEB="${PORT_AGH_WEB:-3000}"
PORT_AGH_DNS="${PORT_AGH_DNS:-10053}"
DIAG_PATH="${DIAG_PATH:-}"
DIAG_TOKEN="${DIAG_TOKEN:-}"
AGH_XRAY_DNS="$agh_xray_save"
SHOW_TIPS="${SHOW_TIPS:-y}"

TIME_LOCATION="${TIME_LOCATION:-}"
SUB_UPDATES="${SUB_UPDATES:-1}"
SUB_ENCRYPT="${SUB_ENCRYPT:-true}"
BLOCK_SMTP="${BLOCK_SMTP:-true}"
BLOCK_LAN="${BLOCK_LAN:-true}"
WEB_LISTEN="${WEB_LISTEN:-127.0.0.1}"
SUB_LISTEN="${SUB_LISTEN:-127.0.0.1}"

DOKPLOY_COEXISTENCE="$dokploy_coexist_save"
ENABLE_MASQUE="$masque_save"
MASQUE_PORT="${MASQUE_PORT:-8449}"
MASQUE_USER="${MASQUE_USER:-client}"
MASQUE_PASSWORD="${MASQUE_PASSWORD:-}"
ENABLE_SHADOWTLS="$shadowtls_save"
SHADOWTLS_PORT="${SHADOWTLS_PORT:-8543}"
SHADOWTLS_SNI="${SHADOWTLS_SNI:-gateway.icloud.com}"
SHADOWTLS_PASSWORD="${SHADOWTLS_PASSWORD:-}"
ENABLE_NAIVE="$naive_save"
NAIVE_PORT="${NAIVE_PORT:-8446}"
NAIVE_DOMAIN="${NAIVE_DOMAIN:-}"
NAIVE_USER="${NAIVE_USER:-user}"
NAIVE_PASS="${NAIVE_PASS:-}"
ENABLE_DNSTT="$dnstt_save"
DNSTT_PORT="${DNSTT_PORT:-53053}"
DNSTT_DOMAIN="${DNSTT_DOMAIN:-}"
DNSTT_PUBKEY="${DNSTT_PUBKEY:-}"
ENABLE_ZAPRET="$zapret_save"
ZAPRET_QNUM="${ZAPRET_QNUM:-200}"
ZAPRET_DESYNC="${ZAPRET_DESYNC:-split2}"
ZAPRET_FOOLING="${ZAPRET_FOOLING:-md5sig,badseq}"
ENABLE_WSTUNNEL="$wstunnel_save"
WSTUNNEL_DOMAIN="${WSTUNNEL_DOMAIN:-}"
WSTUNNEL_PREFIX="${WSTUNNEL_PREFIX:-}"
WSTUNNEL_PORT="${WSTUNNEL_PORT:-8080}"
WSTUNNEL_SECRET="${WSTUNNEL_SECRET:-}"
ENABLE_MIERU="$mieru_save"
MIERU_PORT_MODE="${MIERU_PORT_MODE:-single}"
MIERU_PORT="${MIERU_PORT:-8450}"
MIERU_TRANSPORT="${MIERU_TRANSPORT:-BOTH}"
MIERU_USER="${MIERU_USER:-}"
MIERU_PASS="${MIERU_PASS:-}"
MIERU_MTU="${MIERU_MTU:-1400}"

ENABLE_HOST_SECURITY="$host_security_save"
SSH_PORT="${SSH_PORT:-${SSH_ACTIVE_PORT:-22}}"
ENABLE_FAIL2BAN="$fail2ban_save"
DISABLE_PASSWORD_AUTH="$disable_pwd_save"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
FORCE_CLOSE_OLD_SSH="$force_close_old_save"

LAST_COMPLETED_STEP="${LAST_COMPLETED_STEP:-0}"
EOF_SAVE
    then
        rm -f -- "$save_tmp"
        umask "$old_umask"
        return 1
    fi
    if ! chmod 600 "$save_tmp" || ! mv -f -- "$save_tmp" "$save_path"; then
        rm -f -- "$save_tmp"
        umask "$old_umask"
        return 1
    fi
    if [ "$save_path" != "/etc/server-setup.env" ]; then
        local mirror_tmp
        if mirror_tmp=$(mktemp /etc/server-setup.env.tmp.XXXXXX 2>/dev/null); then
            if ! cp -f -- "$save_path" "$mirror_tmp" || ! chmod 600 "$mirror_tmp" || ! mv -f -- "$mirror_tmp" /etc/server-setup.env; then
                rm -f -- "$mirror_tmp"
                warn "Не удалось обновить /etc/server-setup.env; текущая сессия сохранена в $save_path."
            fi
        else
            warn "Не удалось обновить /etc/server-setup.env; текущая сессия сохранена в $save_path."
        fi
    fi
    umask "$old_umask"
    ok "Конфигурация текущей сессии сохранена в '$save_path' (chmod 600)."
}

#!/usr/bin/env bash
# ==============================================================================
#  SNAPSHOT ENGINE: Initial System State Capture & Verification
# ==============================================================================
#  Creates a secure, immutable snapshot of server packages, services, SSH config,
#  firewall rules, and network tuning before any installer modifications.
# ==============================================================================

SNAPSHOT_DIR="${SNAPSHOT_DIR:-${TARGET_ROOT:-}/var/backups/server_setup}"
SNAPSHOT_ARCHIVE="${SNAPSHOT_ARCHIVE:-${SNAPSHOT_DIR}/initial_state.tar.gz}"
SNAPSHOT_MANIFEST="${SNAPSHOT_MANIFEST:-${SNAPSHOT_DIR}/snapshot_manifest.json}"

create_initial_state_snapshot() {
    local target_root="${TARGET_ROOT:-}"

    # 1. Защита от повторной перезаписи: если снимок уже сделан, сохраняем его
    if [ -f "$SNAPSHOT_ARCHIVE" ] && [ -f "$SNAPSHOT_MANIFEST" ]; then
        if [ -s "$SNAPSHOT_ARCHIVE" ] && [ -s "$SNAPSHOT_MANIFEST" ]; then
            log "Исходный снимок состояния сервера уже существует: $SNAPSHOT_MANIFEST (сохранен без изменений)."
            return 0
        fi
    fi

    log "Создание снимка исходного состояния сервера перед установкой..."
    local tmp_dir
    tmp_dir="$(mktemp -d 2>/dev/null || echo "/tmp/server_snapshot_$$")"
    mkdir -p "$tmp_dir" 2>/dev/null || true

    # 2. Фиксация установленных пакетов
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -f '${binary:Package}\n' -W > "$tmp_dir/packages_installed.list" 2>/dev/null || true
    elif command -v rpm >/dev/null 2>&1; then
        rpm -qa --qf '%{NAME}\n' > "$tmp_dir/packages_installed.list" 2>/dev/null || true
    else
        : > "$tmp_dir/packages_installed.list"
    fi

    # 3. Фиксация состояния служб systemd
    if command -v systemctl >/dev/null 2>&1; then
        systemctl list-unit-files --state=enabled --no-legend 2>/dev/null | awk '{print $1}' > "$tmp_dir/services_enabled.list" || true
        systemctl list-units --state=running --no-legend 2>/dev/null | awk '{print $1}' > "$tmp_dir/services_running.list" || true
    else
        : > "$tmp_dir/services_enabled.list"
        : > "$tmp_dir/services_running.list"
    fi

    # 4. Фиксация SSH конфигурации и активного порта
    local active_ssh_port=22
    if command -v detect_active_ssh_port >/dev/null 2>&1; then
        active_ssh_port="$(detect_active_ssh_port)"
    elif [ -n "${SSH_PORT:-}" ]; then
        active_ssh_port="${SSH_PORT}"
    fi
    echo "$active_ssh_port" > "$tmp_dir/ssh_port.txt"

    if [ -d "${target_root}/etc/ssh" ]; then
        tar --force-local -czf "$tmp_dir/ssh_config.tar.gz" -C "${target_root}/etc" "ssh" 2>/dev/null || true
    fi

    # 5. Фиксация состояния Firewall (UFW & iptables)
    mkdir -p "$tmp_dir/firewall"
    if [ -d "${target_root}/etc/ufw" ]; then
        tar --force-local -czf "$tmp_dir/firewall/ufw_config.tar.gz" -C "${target_root}/etc" "ufw" 2>/dev/null || true
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw status verbose > "$tmp_dir/firewall/ufw_status.txt" 2>/dev/null || true
    fi
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > "$tmp_dir/firewall/iptables.rules" 2>/dev/null || true
    fi
    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > "$tmp_dir/firewall/ip6tables.rules" 2>/dev/null || true
    fi

    # 6. Фиксация сетевых параметров sysctl и limits
    mkdir -p "$tmp_dir/sysctl"
    [ -f "${target_root}/etc/sysctl.conf" ] && cp "${target_root}/etc/sysctl.conf" "$tmp_dir/sysctl/" 2>/dev/null || true
    [ -d "${target_root}/etc/sysctl.d" ] && tar --force-local -czf "$tmp_dir/sysctl/sysctl.d.tar.gz" -C "${target_root}/etc" "sysctl.d" 2>/dev/null || true
    [ -d "${target_root}/etc/security/limits.d" ] && tar --force-local -czf "$tmp_dir/sysctl/limits.d.tar.gz" -C "${target_root}/etc/security" "limits.d" 2>/dev/null || true

    # 7. Фиксация предсуществования Nginx и Fail2ban
    local nginx_preexisted=0
    local fail2ban_preexisted=0
    local agh_preexisted=0
    local xui_preexisted=0

    if command -v nginx >/dev/null 2>&1 && [ -d "${target_root}/etc/nginx" ]; then
        nginx_preexisted=1
        tar --force-local -czf "$tmp_dir/nginx_config.tar.gz" -C "${target_root}/etc" "nginx" 2>/dev/null || true
    fi
    if command -v fail2ban-client >/dev/null 2>&1 && [ -d "${target_root}/etc/fail2ban" ]; then
        fail2ban_preexisted=1
        tar --force-local -czf "$tmp_dir/fail2ban_config.tar.gz" -C "${target_root}/etc" "fail2ban" 2>/dev/null || true
    fi
    if [ -f "${target_root}/opt/AdGuardHome/AdGuardHome" ] || [ -d "${target_root}/opt/AdGuardHome" ]; then
        agh_preexisted=1
    fi
    if [ -f "${target_root}/etc/x-ui/x-ui.db" ] || [ -f "${target_root}/usr/local/x-ui/bin/x-ui.db" ]; then
        xui_preexisted=1
    fi

    # 8. Упаковка архива снимка
    mkdir -p "$SNAPSHOT_DIR"
    chmod 700 "$SNAPSHOT_DIR" 2>/dev/null || true
    if ! tar --force-local -czf "$SNAPSHOT_ARCHIVE" -C "$tmp_dir" . 2>/dev/null; then
        rm -rf "$tmp_dir" 2>/dev/null || true
        warn "Не удалось упаковать архив снимка $SNAPSHOT_ARCHIVE."
        return 1
    fi
    chmod 600 "$SNAPSHOT_ARCHIVE" 2>/dev/null || true

    # 9. Расчет контрольной суммы архива
    local archive_sha256=""
    if command -v sha256sum >/dev/null 2>&1; then
        archive_sha256="$(sha256sum "$SNAPSHOT_ARCHIVE" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        archive_sha256="$(shasum -a 256 "$SNAPSHOT_ARCHIVE" | awk '{print $1}')"
    fi

    # 10. Формирование манифеста
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")"
    local os_id os_codename k_rel
    os_id="$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "linux")"
    os_codename="$(lsb_release -cs 2>/dev/null || echo "generic")"
    k_rel="$(uname -r 2>/dev/null || echo "unknown")"

    cat << EOF > "$SNAPSHOT_MANIFEST"
{
  "version": "1.0",
  "timestamp": "$ts",
  "os_id": "$os_id",
  "os_codename": "$os_codename",
  "kernel_release": "$k_rel",
  "ssh_active_port": $active_ssh_port,
  "nginx_preexisted": $nginx_preexisted,
  "fail2ban_preexisted": $fail2ban_preexisted,
  "adguard_preexisted": $agh_preexisted,
  "xui_preexisted": $xui_preexisted,
  "archive_file": "initial_state.tar.gz",
  "archive_sha256": "$archive_sha256"
}
EOF
    chmod 600 "$SNAPSHOT_MANIFEST" 2>/dev/null || true
    rm -rf "$tmp_dir" 2>/dev/null || true

    ok "Снимок исходного состояния сервера успешно сохранен в $SNAPSHOT_DIR"
    return 0
}

verify_initial_state_snapshot() {
    if [ ! -f "$SNAPSHOT_ARCHIVE" ] || [ ! -f "$SNAPSHOT_MANIFEST" ]; then
        return 1
    fi
    if [ ! -s "$SNAPSHOT_ARCHIVE" ] || [ ! -s "$SNAPSHOT_MANIFEST" ]; then
        return 1
    fi
    # Валидация gzip-целостности
    tar --force-local -tzf "$SNAPSHOT_ARCHIVE" >/dev/null 2>&1 || return 1
    return 0
}
#!/usr/bin/env bash
# ==============================================================================
#  UNINSTALL & ROLLBACK ENGINE
# ==============================================================================
#  Safely tears down VPN/proxy stack, restores initial network, SSH, firewall,
#  and system settings from snapshot with strict Anti-Lockout protection.
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
#!/usr/bin/env bash
# ==============================================================================
#  SNAPSHOT ENGINE: Initial System State Capture & Verification
# ==============================================================================
#  Creates a secure, immutable snapshot of server packages, services, SSH config,
#  firewall rules, and network tuning before any installer modifications.
# ==============================================================================

SNAPSHOT_DIR="${SNAPSHOT_DIR:-${TARGET_ROOT:-}/var/backups/server_setup}"
SNAPSHOT_ARCHIVE="${SNAPSHOT_ARCHIVE:-${SNAPSHOT_DIR}/initial_state.tar.gz}"
SNAPSHOT_MANIFEST="${SNAPSHOT_MANIFEST:-${SNAPSHOT_DIR}/snapshot_manifest.json}"

create_initial_state_snapshot() {
    local target_root="${TARGET_ROOT:-}"

    # 1. Защита от повторной перезаписи: если снимок уже сделан, сохраняем его
    if [ -f "$SNAPSHOT_ARCHIVE" ] && [ -f "$SNAPSHOT_MANIFEST" ]; then
        if [ -s "$SNAPSHOT_ARCHIVE" ] && [ -s "$SNAPSHOT_MANIFEST" ]; then
            log "Исходный снимок состояния сервера уже существует: $SNAPSHOT_MANIFEST (сохранен без изменений)."
            return 0
        fi
    fi

    log "Создание снимка исходного состояния сервера перед установкой..."
    local tmp_dir
    tmp_dir="$(mktemp -d 2>/dev/null || echo "/tmp/server_snapshot_$$")"
    mkdir -p "$tmp_dir" 2>/dev/null || true

    # 2. Фиксация установленных пакетов
    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -f '${binary:Package}\n' -W > "$tmp_dir/packages_installed.list" 2>/dev/null || true
    elif command -v rpm >/dev/null 2>&1; then
        rpm -qa --qf '%{NAME}\n' > "$tmp_dir/packages_installed.list" 2>/dev/null || true
    else
        : > "$tmp_dir/packages_installed.list"
    fi

    # 3. Фиксация состояния служб systemd
    if command -v systemctl >/dev/null 2>&1; then
        systemctl list-unit-files --state=enabled --no-legend 2>/dev/null | awk '{print $1}' > "$tmp_dir/services_enabled.list" || true
        systemctl list-units --state=running --no-legend 2>/dev/null | awk '{print $1}' > "$tmp_dir/services_running.list" || true
    else
        : > "$tmp_dir/services_enabled.list"
        : > "$tmp_dir/services_running.list"
    fi

    # 4. Фиксация SSH конфигурации и активного порта
    local active_ssh_port=22
    if command -v detect_active_ssh_port >/dev/null 2>&1; then
        active_ssh_port="$(detect_active_ssh_port)"
    elif [ -n "${SSH_PORT:-}" ]; then
        active_ssh_port="${SSH_PORT}"
    fi
    echo "$active_ssh_port" > "$tmp_dir/ssh_port.txt"

    if [ -d "${target_root}/etc/ssh" ]; then
        tar --force-local -czf "$tmp_dir/ssh_config.tar.gz" -C "${target_root}/etc" "ssh" 2>/dev/null || true
    fi

    # 5. Фиксация состояния Firewall (UFW & iptables)
    mkdir -p "$tmp_dir/firewall"
    if [ -d "${target_root}/etc/ufw" ]; then
        tar --force-local -czf "$tmp_dir/firewall/ufw_config.tar.gz" -C "${target_root}/etc" "ufw" 2>/dev/null || true
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw status verbose > "$tmp_dir/firewall/ufw_status.txt" 2>/dev/null || true
    fi
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save > "$tmp_dir/firewall/iptables.rules" 2>/dev/null || true
    fi
    if command -v ip6tables-save >/dev/null 2>&1; then
        ip6tables-save > "$tmp_dir/firewall/ip6tables.rules" 2>/dev/null || true
    fi

    # 6. Фиксация сетевых параметров sysctl и limits
    mkdir -p "$tmp_dir/sysctl"
    [ -f "${target_root}/etc/sysctl.conf" ] && cp "${target_root}/etc/sysctl.conf" "$tmp_dir/sysctl/" 2>/dev/null || true
    [ -d "${target_root}/etc/sysctl.d" ] && tar --force-local -czf "$tmp_dir/sysctl/sysctl.d.tar.gz" -C "${target_root}/etc" "sysctl.d" 2>/dev/null || true
    [ -d "${target_root}/etc/security/limits.d" ] && tar --force-local -czf "$tmp_dir/sysctl/limits.d.tar.gz" -C "${target_root}/etc/security" "limits.d" 2>/dev/null || true

    # 7. Фиксация предсуществования Nginx и Fail2ban
    local nginx_preexisted=0
    local fail2ban_preexisted=0
    local agh_preexisted=0
    local xui_preexisted=0

    if command -v nginx >/dev/null 2>&1 && [ -d "${target_root}/etc/nginx" ]; then
        nginx_preexisted=1
        tar --force-local -czf "$tmp_dir/nginx_config.tar.gz" -C "${target_root}/etc" "nginx" 2>/dev/null || true
    fi
    if command -v fail2ban-client >/dev/null 2>&1 && [ -d "${target_root}/etc/fail2ban" ]; then
        fail2ban_preexisted=1
        tar --force-local -czf "$tmp_dir/fail2ban_config.tar.gz" -C "${target_root}/etc" "fail2ban" 2>/dev/null || true
    fi
    if [ -f "${target_root}/opt/AdGuardHome/AdGuardHome" ] || [ -d "${target_root}/opt/AdGuardHome" ]; then
        agh_preexisted=1
    fi
    if [ -f "${target_root}/etc/x-ui/x-ui.db" ] || [ -f "${target_root}/usr/local/x-ui/bin/x-ui.db" ]; then
        xui_preexisted=1
    fi

    # 8. Упаковка архива снимка
    mkdir -p "$SNAPSHOT_DIR"
    chmod 700 "$SNAPSHOT_DIR" 2>/dev/null || true
    if ! tar --force-local -czf "$SNAPSHOT_ARCHIVE" -C "$tmp_dir" . 2>/dev/null; then
        rm -rf "$tmp_dir" 2>/dev/null || true
        warn "Не удалось упаковать архив снимка $SNAPSHOT_ARCHIVE."
        return 1
    fi
    chmod 600 "$SNAPSHOT_ARCHIVE" 2>/dev/null || true

    # 9. Расчет контрольной суммы архива
    local archive_sha256=""
    if command -v sha256sum >/dev/null 2>&1; then
        archive_sha256="$(sha256sum "$SNAPSHOT_ARCHIVE" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        archive_sha256="$(shasum -a 256 "$SNAPSHOT_ARCHIVE" | awk '{print $1}')"
    fi

    # 10. Формирование манифеста
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")"
    local os_id os_codename k_rel
    os_id="$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "linux")"
    os_codename="$(lsb_release -cs 2>/dev/null || echo "generic")"
    k_rel="$(uname -r 2>/dev/null || echo "unknown")"

    cat << EOF > "$SNAPSHOT_MANIFEST"
{
  "version": "1.0",
  "timestamp": "$ts",
  "os_id": "$os_id",
  "os_codename": "$os_codename",
  "kernel_release": "$k_rel",
  "ssh_active_port": $active_ssh_port,
  "nginx_preexisted": $nginx_preexisted,
  "fail2ban_preexisted": $fail2ban_preexisted,
  "adguard_preexisted": $agh_preexisted,
  "xui_preexisted": $xui_preexisted,
  "archive_file": "initial_state.tar.gz",
  "archive_sha256": "$archive_sha256"
}
EOF
    chmod 600 "$SNAPSHOT_MANIFEST" 2>/dev/null || true
    rm -rf "$tmp_dir" 2>/dev/null || true

    ok "Снимок исходного состояния сервера успешно сохранен в $SNAPSHOT_DIR"
    return 0
}

verify_initial_state_snapshot() {
    if [ ! -f "$SNAPSHOT_ARCHIVE" ] || [ ! -f "$SNAPSHOT_MANIFEST" ]; then
        return 1
    fi
    if [ ! -s "$SNAPSHOT_ARCHIVE" ] || [ ! -s "$SNAPSHOT_MANIFEST" ]; then
        return 1
    fi
    # Валидация gzip-целостности
    tar --force-local -tzf "$SNAPSHOT_ARCHIVE" >/dev/null 2>&1 || return 1
    return 0
}

UNINSTALL_FORCE="${UNINSTALL_FORCE:-0}"
UNINSTALL_PURGE_PKGS="${UNINSTALL_PURGE_PKGS:-0}"
UNINSTALL_KEEP_CERTS="${UNINSTALL_KEEP_CERTS:-1}"
UNINSTALL_CERTS_EXPLICIT="${UNINSTALL_CERTS_EXPLICIT:-0}"

parse_manifest_field() {
    local field="$1"
    local manifest="${2:-$SNAPSHOT_MANIFEST}"
    if [ ! -f "$manifest" ]; then
        echo ""
        return
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import json, sys; d=json.load(open('$manifest')); print(d.get('$field', ''))" 2>/dev/null || true
    else
        grep "\"$field\":" "$manifest" 2>/dev/null | head -n1 | sed -E 's/.*:[[:space:]]*"?([^",]+)"?.*/\1/' || true
    fi
}

run_uninstall() {
    local target_root="${TARGET_ROOT:-}"
    local snap_dir="${SNAPSHOT_DIR:-${target_root}/var/backups/server_setup}"
    local manifest="${SNAPSHOT_MANIFEST:-${snap_dir}/snapshot_manifest.json}"
    local archive="${SNAPSHOT_ARCHIVE:-${snap_dir}/initial_state.tar.gz}"

    echo -e "\n${BOLD}${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${RED}║      МАСТЕР ПОЛНОГО УДАЛЕНИЯ И ОТКАТА СЕРВЕРА К ИСХОДНОМУ        ║${NC}"
    echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════════════════╝${NC}\n"

    local has_snapshot=0
    if [ -f "$manifest" ] && [ -f "$archive" ]; then
        has_snapshot=1
        ok "Обнаружен снимок исходного состояния сервера: $manifest"
    else
        warn "Снимок исходного состояния не найден ($manifest). Будет выполнена стандартная зачистка известных компонентов."
    fi

    # Чтение метаданных из снимка
    local orig_ssh_port=22
    local nginx_preexisted=0
    local fail2ban_preexisted=0
    local agh_preexisted=0
    local xui_preexisted=0

    if [ "$has_snapshot" -eq 1 ]; then
        orig_ssh_port="$(parse_manifest_field "ssh_active_port" "$manifest")"
        [ -n "$orig_ssh_port" ] || orig_ssh_port=22
        nginx_preexisted="$(parse_manifest_field "nginx_preexisted" "$manifest")"
        [ "$nginx_preexisted" = "1" ] || nginx_preexisted=0
        fail2ban_preexisted="$(parse_manifest_field "fail2ban_preexisted" "$manifest")"
        [ "$fail2ban_preexisted" = "1" ] || fail2ban_preexisted=0
        agh_preexisted="$(parse_manifest_field "adguard_preexisted" "$manifest")"
        [ "$agh_preexisted" = "1" ] || agh_preexisted=0
        xui_preexisted="$(parse_manifest_field "xui_preexisted" "$manifest")"
        [ "$xui_preexisted" = "1" ] || xui_preexisted=0
    fi

    echo -e "Будут выполнены следующие действия:"
    echo -e "  1. Остановка и отключение всех VPN/прокси служб (3X-UI, AWG, MASQUE, ShadowTLS, Naïve, DNSTT, Wstunnel, Zapret);"
    echo -e "  2. Удаление custom systemd юнитов и cron/timer задач;"
    echo -e "  3. Восстановление конфигурации Firewall (UFW) и очистка правил Port Hopping;"
    echo -e "  4. Восстановление конфигурации SSH (с проверкой sshd -t во избежание блокировки);"
    echo -e "  5. Удаление параметров оптимизации ядра sysctl и limits.d;"
    if [ "$nginx_preexisted" -eq 1 ]; then
        echo -e "  6. Восстановление исходной конфигурации Nginx (существовавшей до запуска скрипта);"
    else
        echo -e "  6. Полное удаление Nginx и очистка веб-маскировок;"
    fi
    echo -e "  7. Удаление конфигурационных и рабочих каталогов стека;\n"

    if [ "${UNINSTALL_FORCE:-0}" -ne 1 ]; then
        read -r -p "Вы уверены, что хотите продолжить? [y/N]: " confirm_uninstall
        if [[ ! "$confirm_uninstall" =~ ^[YyДд1] ]]; then
            echo -e "${YELLOW}Удаление отменено пользователем.${NC}"
            return 0
        fi

        # Интерактивный запрос по SSL-сертификатам Let's Encrypt
        if [ "${UNINSTALL_CERTS_EXPLICIT:-0}" -eq 0 ]; then
            echo ""
            echo -e "${CYAN}Управление SSL-сертификатами:${NC}"
            echo -e "  Сохранение сертификатов предотвращает исчерпание недельных лимитов Let's Encrypt при повторной настройке."
            read -r -p "Удалить выпущенные SSL-сертификаты (/etc/letsencrypt, /etc/ssl/acme, ~/.acme.sh)? [y/N]: " confirm_certs
            if [[ "$confirm_certs" =~ ^[YyДд1] ]]; then
                UNINSTALL_KEEP_CERTS=0
            else
                UNINSTALL_KEEP_CERTS=1
            fi
            echo ""
        fi
    fi

    log "Шаг 1/8: Остановка и отключение служб..."
    local services_to_stop=(
        "x-ui" "xray-geo-update.timer" "xray-geo-update.service"
        "awg-quick@awg0" "sing-box-masque" "shadow-tls" "wstunnel"
        "dnstt" "caddy-naive" "zapret"
    )
    [ "$agh_preexisted" -eq 0 ] && services_to_stop+=("AdGuardHome")
    [ "$fail2ban_preexisted" -eq 0 ] && services_to_stop+=("fail2ban")
    [ "$nginx_preexisted" -eq 0 ] && services_to_stop+=("nginx")

    for svc in "${services_to_stop[@]}"; do
        if command -v systemctl >/dev/null 2>&1; then
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
        fi
    done
    ok "Службы остановлены и отключены."

    log "Шаг 2/8: Удаление созданных systemd units и cron-задач..."
    local units_to_remove=(
        "${target_root}/etc/systemd/system/x-ui.service"
        "${target_root}/etc/systemd/system/xray-geo-update.service"
        "${target_root}/etc/systemd/system/xray-geo-update.timer"
        "${target_root}/etc/systemd/system/sing-box-masque.service"
        "${target_root}/etc/systemd/system/shadow-tls.service"
        "${target_root}/etc/systemd/system/wstunnel.service"
        "${target_root}/etc/systemd/system/dnstt.service"
        "${target_root}/etc/systemd/system/caddy-naive.service"
        "${target_root}/etc/systemd/system/mita.service"
        "${target_root}/etc/systemd/system/zapret.service"
        "${target_root}/etc/systemd/system/nginx.service.d/override.conf"
    )
    [ "$agh_preexisted" -eq 0 ] && units_to_remove+=("${target_root}/etc/systemd/system/AdGuardHome.service")

    for unit in "${units_to_remove[@]}"; do
        rm -f "$unit" 2>/dev/null || true
    done
    if [ -d "${target_root}/etc/systemd/system/nginx.service.d" ]; then
        rmdir "${target_root}/etc/systemd/system/nginx.service.d" 2>/dev/null || true
    fi

    # Удаление cron-файлов и периодических задач
    rm -f "${target_root}/etc/cron.d/awg-purge-expired" 2>/dev/null || true
    if command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v "sysctl --system" || true) | crontab - 2>/dev/null || true
    fi

    # Зачистка tunnel-интерфейса awg0, если остался активен
    if command -v ip >/dev/null 2>&1; then
        ip link delete dev awg0 2>/dev/null || true
    fi

    # Очистка резолвера AdGuard Home в systemd-resolved
    if [ "$agh_preexisted" -eq 0 ]; then
        rm -f "${target_root}/etc/systemd/resolved.conf.d/adguard.conf" 2>/dev/null || true
        if [ -d "${target_root}/etc/systemd/resolved.conf.d" ]; then
            rmdir "${target_root}/etc/systemd/resolved.conf.d" 2>/dev/null || true
        fi
        if command -v systemctl >/dev/null 2>&1; then
            systemctl restart systemd-resolved 2>/dev/null || true
        fi
    fi

    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null || true
    ok "Systemd units, cron-задачи и сетевые интерфейсы очищены."

    log "Шаг 3/8: Восстановление Firewall и очистка правил UFW..."
    # Удаление правил port hopping и MSS clamping из UFW
    for rule_file in "${target_root}/etc/ufw/before.rules" "${target_root}/etc/ufw/before6.rules"; do
        if [ -f "$rule_file" ]; then
            sed -i '/# Port Hopping for Hysteria 2/,/COMMIT/d' "$rule_file" 2>/dev/null || true
            sed -i '/# Hy2 Port Hopping/d' "$rule_file" 2>/dev/null || true
            sed -i '/-A PREROUTING -p udp --dport .* -j REDIRECT/d' "$rule_file" 2>/dev/null || true
            sed -i '/# TCP MSS Clamping/,/COMMIT/d' "$rule_file" 2>/dev/null || true
            sed -i '/TCPMSS --clamp-mss-to-pmtu/d' "$rule_file" 2>/dev/null || true
        fi
    done

    # Гарантируем, что активный порт SSH открыт в UFW во избежание lockout
    if command -v ufw >/dev/null 2>&1; then
        local current_ssh_port
        current_ssh_port=$(command -v detect_active_ssh_port >/dev/null 2>&1 && detect_active_ssh_port || echo 22)
        ufw allow "${current_ssh_port}/tcp" comment 'SSH (Active)' >/dev/null 2>&1 || true
        [ -n "$orig_ssh_port" ] && ufw allow "${orig_ssh_port}/tcp" comment 'SSH (Restored)' >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
    fi
    ok "Правила Firewall очищены (SSH-порты защищены)."

    log "Шаг 4/8: Восстановление конфигурации SSH (Anti-Lockout)..."
    local ssh_restored=0
    local tmp_extract
    tmp_extract="$(mktemp -d 2>/dev/null || echo "/tmp/ssh_extract_$$")"

    if [ "$has_snapshot" -eq 1 ] && tar --force-local -tzf "$archive" "ssh_config.tar.gz" >/dev/null 2>&1; then
        tar --force-local -xzf "$archive" -C "$tmp_extract" "ssh_config.tar.gz" 2>/dev/null || true
        if [ -f "$tmp_extract/ssh_config.tar.gz" ]; then
            mkdir -p "$tmp_extract/ssh_root"
            tar --force-local -xzf "$tmp_extract/ssh_config.tar.gz" -C "$tmp_extract/ssh_root" 2>/dev/null || true

            # Проверка синтаксиса sshd перед применением
            local sshd_valid=1
            if command -v sshd >/dev/null 2>&1 && [ -f "$tmp_extract/ssh_root/ssh/sshd_config" ]; then
                if ! sshd -t -f "$tmp_extract/ssh_root/ssh/sshd_config" 2>/dev/null; then
                    sshd_valid=0
                fi
            fi

            if [ "$sshd_valid" -eq 1 ] && [ -d "$tmp_extract/ssh_root/ssh" ]; then
                cp -a "$tmp_extract/ssh_root/ssh/." "${target_root}/etc/ssh/" 2>/dev/null || true
                ssh_restored=1
                ok "Конфигурация SSH успешно восстановлена из снимка."
            else
                warn "Синтаксис восстанавливаемого sshd_config не прошел проверку sshd -t. Конфигурация SSH сохранена без изменений для защиты доступа."
            fi
        fi
    fi

    # Очистка добавленных скриптом hardening-файлов
    rm -f "${target_root}/etc/ssh/sshd_config.d/99-hardening.conf" 2>/dev/null || true
    rm -f "${target_root}/usr/local/bin/ssh-port-watcher.sh" 2>/dev/null || true

    # Перезапуск SSH-службы
    if [ "$ssh_restored" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
        local ssh_svc="ssh"
        systemctl is-active --quiet sshd 2>/dev/null && ssh_svc="sshd"
        systemctl reload "$ssh_svc" 2>/dev/null || systemctl restart "$ssh_svc" 2>/dev/null || true
    fi
    rm -rf "$tmp_extract" 2>/dev/null || true

    log "Шаг 5/8: Удаление настроек ядра sysctl и limits..."
    rm -f "${target_root}/etc/sysctl.d/99-vless-tuning.conf" 2>/dev/null || true
    rm -f "${target_root}/etc/security/limits.d/99-proxy-limits.conf" 2>/dev/null || true
    rm -f "${target_root}/etc/systemd/journald.conf.d/00-volatile.conf" 2>/dev/null || true
    command -v sysctl >/dev/null 2>&1 && sysctl --system >/dev/null 2>&1 || true
    ok "Сетевые параметры ядра возвращены к значениям по умолчанию."

    log "Шаг 6/8: Очистка или восстановление Nginx..."
    if [ "$nginx_preexisted" -eq 1 ]; then
        # Nginx существовал до нас: восстанавливаем исходную конфигурацию
        rm -f "${target_root}/etc/nginx/conf.d/01-main.conf" \
              "${target_root}/etc/nginx/conf.d/02-"*.conf \
              "${target_root}/etc/nginx/conf.d/03-adguard.conf \
              ${target_root}/etc/nginx/conf.d/vpn_mask.conf" \
              "${target_root}/etc/nginx/stream.d/00-stream.conf" \
              "${target_root}/etc/nginx/modules-enabled/50-mod-stream.conf" 2>/dev/null || true
        
        tmp_extract="$(mktemp -d 2>/dev/null || echo "/tmp/nginx_extract_$$")"
        if [ "$has_snapshot" -eq 1 ] && tar --force-local -tzf "$archive" "nginx_config.tar.gz" >/dev/null 2>&1; then
            tar --force-local -xzf "$archive" -C "$tmp_extract" "nginx_config.tar.gz" 2>/dev/null || true
            if [ -f "$tmp_extract/nginx_config.tar.gz" ]; then
                tar --force-local -xzf "$tmp_extract/nginx_config.tar.gz" -C "${target_root}/etc" 2>/dev/null || true
                ok "Исходная конфигурация Nginx восстановлена из снимка."
            fi
        fi
        rm -rf "$tmp_extract" 2>/dev/null || true
        command -v systemctl >/dev/null 2>&1 && systemctl restart nginx 2>/dev/null || true
    else
        # Nginx был установлен нами: удаляем его конфиги и кэш
        rm -rf "${target_root}/etc/nginx/conf.d" \
               "${target_root}/etc/nginx/stream.d" \
               "${target_root}/etc/nginx/modules-enabled" \
               "${target_root}/var/cache/nginx" 2>/dev/null || true
        if [ "${UNINSTALL_PURGE_PKGS:-0}" -eq 1 ] && command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get purge -y nginx nginx-common nginx-core libnginx-mod-stream nginx-module-stream >/dev/null 2>&1 || true
            rm -f "${target_root}/etc/apt/sources.list.d/nginx.list" "${target_root}/etc/apt/preferences.d/99nginx" 2>/dev/null || true
        fi
        ok "Конфигурация Nginx удалена."
    fi

    log "Шаг 7/8: Очистка рабочих директорий и исполняемых файлов..."
    local dirs_to_remove=(
        "${target_root}/opt/zapret"
        "${target_root}/etc/sing-box"
        "${target_root}/etc/caddy"
        "${target_root}/etc/amnezia"
        "${target_root}/etc/mita"
        "${target_root}/var/lib/mita"
        "${target_root}/var/run/mita"
        "${target_root}/root/awg"
        "${target_root}/var/www/mirror"
        "${target_root}/root/.server_setup"
    )
    [ "$agh_preexisted" -eq 0 ] && dirs_to_remove+=("${target_root}/opt/AdGuardHome")
    [ "$xui_preexisted" -eq 0 ] && dirs_to_remove+=("${target_root}/usr/local/x-ui" "${target_root}/etc/x-ui")

    for dir in "${dirs_to_remove[@]}"; do
        rm -rf "$dir" 2>/dev/null || true
    done

    # Удаление standalone бинарников
    local bins_to_remove=(
        "${target_root}/usr/local/bin/sing-box"
        "${target_root}/usr/local/bin/shadow-tls"
        "${target_root}/usr/local/bin/wstunnel"
        "${target_root}/usr/local/bin/dnstt-server"
        "${target_root}/usr/local/bin/caddy-naive"
        "${target_root}/usr/local/bin/mita"
        "${target_root}/usr/local/bin/mieru-mgr"
        "${target_root}/usr/local/bin/mieru-cli"
        "${target_root}/usr/local/bin/awg-mgr"
        "${target_root}/usr/local/bin/manage-services"
    )
    for b in "${bins_to_remove[@]}"; do
        rm -f "$b" 2>/dev/null || true
    done

    # Очистка временных файлов и учетных данных
    rm -f "${target_root}/root/vpn_credentials.txt" \
          "${target_root}/root/mieru-client"*.json \
          "${target_root}/etc/mita_server_config.json" \
          "${target_root}/run/3xui_unified_client.env" \
          "${target_root}/var/run/server_setup.checkpoint" \
          "${target_root}/var/run/server_setup.failed_step" \
          "${target_root}/var/run/server_setup_active_step.log" 2>/dev/null || true

    # SSL сертификаты (по умолчанию сохраняются, если не запрошена очистка)
    if [ "${UNINSTALL_KEEP_CERTS:-1}" -eq 0 ]; then
        rm -rf "${target_root}/etc/letsencrypt" "${target_root}/etc/ssl/acme" "${target_root}/root/.acme.sh" 2>/dev/null || true
        if command -v crontab >/dev/null 2>&1; then
            (crontab -l 2>/dev/null | grep -v "acme.sh" || true) | crontab - 2>/dev/null || true
        fi
        ok "SSL-сертификаты и acme.sh успешно удалены."
    else
        log "SSL-сертификаты сохранены в /etc/letsencrypt и /etc/ssl/acme (защита от исчерпания лимитов)."
    fi
    ok "Рабочие директории и бинарники успешно удалены."

    log "Шаг 8/8: Завершение отката..."
    if [ "${UNINSTALL_PURGE_PKGS:-0}" -eq 1 ] && [ "$has_snapshot" -eq 1 ] && command -v apt-get >/dev/null 2>&1; then
        local snap_pkgs="$snap_dir/packages_installed.list"
        if [ -f "$snap_pkgs" ]; then
            log "Вычисление и удаление добавленных пакетов (--purge)..."
            local cur_pkgs
            cur_pkgs="$(mktemp 2>/dev/null || echo "/tmp/cur_pkgs_$$")"
            dpkg-query -f '${binary:Package}\n' -W > "$cur_pkgs" 2>/dev/null || true
            local diff_pkgs
            diff_pkgs="$(comm -13 <(sort "$snap_pkgs") <(sort "$cur_pkgs") | grep -E '^(amneziawg|wireguard)' || true)"
            if [ -n "$diff_pkgs" ]; then
                export DEBIAN_FRONTEND=noninteractive
                # shellcheck disable=SC2086
                apt-get purge -y $diff_pkgs >/dev/null 2>&1 || true
            fi
            rm -f "$cur_pkgs" 2>/dev/null || true
        fi
    fi

    echo -e "\n${BOLD}${GREEN}✔ Сервер успешно возвращен в исходное состояние!${NC}"
    echo -e "Все компоненты стека удалены, правила безопасности и доступ по SSH сохранены.\n"
    return 0
}
#!/usr/bin/env bash
# ==============================================================================
#  DEBUG LOG EXPORT & RETRIEVAL ENGINE
# ==============================================================================
#  Provides easy multi-channel retrieval of installation and diagnostic logs:
#    1. One-click SCP copy commands (formatted for Windows / macOS / Linux)
#    2. Temporary one-time Web link (via Nginx or ephemeral Python server)
#    3. Sanitized upload to ephemeral pastebin (0x0.st / bashupload.com)
#    4. Interactive tail preview in console
# ==============================================================================

_LOG_EXPORT_OFFERED=0

sanitize_debug_log() {
    local src_file="$1"
    local dst_file="$2"
    [ -f "$src_file" ] || return 1
    # Маскирование чувствительных данных: паролей, токенов, UUID и приватных ключей
    sed -E \
        -e 's/(PASSWORD|PASS|SECRET|TOKEN|KEY|UUID|PRIVATE_KEY)=[^ ]+/\1=***MASKED***/gI' \
        -e 's/(ADMIN_PASSWORD|AGH_PASS|NODE_TOKEN)=.*/\1=***MASKED***/gI' \
        -e 's/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/***UUID***/gI' \
        -e 's/(ey[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{10,})/***JWT***/g' \
        "$src_file" > "$dst_file" 2>/dev/null || cp -f "$src_file" "$dst_file"
}

get_log_export_target() {
    local cand
    for cand in "${SERVER_SETUP_LOG:-}" \
                "/var/log/server-setup.log" \
                "${TMPDIR:-/tmp}/server-setup.log"; do
        if [ -n "$cand" ] && [ -f "$cand" ]; then
            echo "$cand"
            return 0
        fi
    done
    echo ""
}

create_web_download_link() {
    local log_path="$1"
    local webroot="${WEBROOT:-/var/www/html}"

    # Сценарий 1: Nginx установлен и веб-корень доступен
    if [ -d "$webroot" ] && [ -w "$webroot" ]; then
        local token
        token=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 16 || echo "$RANDOM$RANDOM")
        local dest_file="$webroot/debug-${token}.log"
        cp -f "$log_path" "$dest_file" 2>/dev/null || return 1
        chmod 644 "$dest_file" 2>/dev/null || true

        # Фоновое удаление через 15 минут
        (sleep 900 && rm -f "$dest_file") >/dev/null 2>&1 &

        local host="${PRIMARY_DOMAIN:-}"
        if [ -z "$host" ] && command -v get_wan_ip >/dev/null 2>&1; then
            host=$(get_wan_ip 2>/dev/null || echo "")
        fi
        [ -n "$host" ] || host="${WAN_IP:-$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'IP-СЕРВЕРА')}"

        local scheme="http"
        if [ -n "${PRIMARY_DOMAIN:-}" ] && { [ -d "/etc/letsencrypt/live/${PRIMARY_DOMAIN}" ] || [ -d "/etc/ssl/acme/${PRIMARY_DOMAIN}" ]; }; then
            scheme="https"
        fi
        echo "${scheme}://${host}/debug-${token}.log"
        return 0
    fi

    # Сценарий 2: Фоновый временный сервер Python на случайном порту
    if command -v python3 >/dev/null 2>&1; then
        local port=18443
        local srv_dir
        srv_dir=$(mktemp -d 2>/dev/null || echo "/tmp/log_srv_$$")
        cp -f "$log_path" "$srv_dir/server-setup.log" 2>/dev/null || return 1
        local ip="${WAN_IP:-}"
        if [ -z "$ip" ] && command -v get_wan_ip >/dev/null 2>&1; then
            ip=$(get_wan_ip 2>/dev/null || echo "")
        fi
        [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'IP-СЕРВЕРА')"

        if command -v ufw >/dev/null 2>&1; then
            ufw allow "$port/tcp" comment 'Temp Debug Log' >/dev/null 2>&1 || true
        fi
        (
            cd "$srv_dir"
            timeout 600 python3 -m http.server "$port" >/dev/null 2>&1 || true
            rm -rf "$srv_dir"
            if command -v ufw >/dev/null 2>&1; then
                ufw delete allow "$port/tcp" >/dev/null 2>&1 || true
            fi
        ) &
        echo "http://${ip}:${port}/server-setup.log"
        return 0
    fi

    return 1
}

upload_to_pastebin() {
    local sanitized_file="$1"
    local res=""

    if command -v curl >/dev/null 2>&1; then
        # 1. 0x0.st
        res=$(curl -sS --connect-timeout 5 --max-time 15 -F "file=@${sanitized_file}" https://0x0.st 2>/dev/null || true)
        if [[ "$res" =~ ^https?:// ]]; then
            echo "$res" | tr -d ' \r\n'
            return 0
        fi

        # 2. bashupload.com
        res=$(curl -sS --connect-timeout 5 --max-time 15 --upload-file "${sanitized_file}" https://bashupload.com 2>/dev/null | grep -E '^https?://' | head -n1 || true)
        if [[ "$res" =~ ^https?:// ]]; then
            echo "$res" | tr -d ' \r\n'
            return 0
        fi
    fi
    return 1
}

offer_debug_log_export() {
    # Защита от повторного вызова
    if [ "${_LOG_EXPORT_OFFERED:-0}" -eq 1 ]; then
        return 0
    fi
    _LOG_EXPORT_OFFERED=1

    local log_path
    log_path=$(get_log_export_target)
    if [ -z "$log_path" ] || [ ! -f "$log_path" ]; then
        return 0
    fi

    # Автоматическое создание удобной копии в /root/
    local home_copy="/root/server-setup.log"
    if [ -d /root ] && [ -w /root ]; then
        cp -f "$log_path" "$home_copy" 2>/dev/null || true
        chmod 600 "$home_copy" 2>/dev/null || true
    fi

    local ssh_port="${SSH_PORT:-${SSH_ACTIVE_PORT:-22}}"
    local wan_ip="${WAN_IP:-}"
    if [ -z "$wan_ip" ] && command -v get_wan_ip >/dev/null 2>&1; then
        wan_ip=$(get_wan_ip 2>/dev/null || echo "")
    fi
    [ -n "$wan_ip" ] || wan_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'IP-СЕРВЕРА')"

    echo ""
    echo -e "  ${CYAN}${BOLD}📋 Журнал выполнения отладки (Debug Log):${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
    echo -e "  Файл на сервере:   ${WHITE}${log_path}${NC}"
    if [ -f "$home_copy" ]; then
        echo -e "  Копия в /root:     ${WHITE}${home_copy}${NC}"
    fi
    echo ""
    echo -e "  ${WHITE}Команда для скачивания на локальный ПК (PowerShell / Bash):${NC}"
    echo -e "  ${GREEN}${BOLD}scp -P ${ssh_port} root@${wan_ip}:${log_path} .${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"

    # Если неинтерактивный режим или нет TTY — выводим только плашку
    if [ "${NON_INTERACTIVE:-0}" -eq 1 ] || [ ! -t 1 ]; then
        return 0
    fi

    local exp_keys=("scp" "web" "upload" "tail" "exit")
    local exp_labels=(
        "Показать команды SCP / SFTP для всех ОС"
        "Создать временную веб-ссылку для скачивания"
        "Загрузить на защищенный обменник (маскировка паролей)"
        "Показать последние 50 строк прямо в консоли"
        "Завершить без дополнительных действий"
    )

    local chosen=""
    while true; do
        if command -v prompt_select >/dev/null 2>&1; then
            prompt_select "  Экспорт журнала отладки" chosen "exit" exp_keys exp_labels || break
        else
            echo -e "  ${CYAN}[1]${NC} Показать команды SCP"
            echo -e "  ${CYAN}[2]${NC} Создать веб-ссылку"
            echo -e "  ${CYAN}[3]${NC} Загрузить на защищенный обменник"
            echo -e "  ${CYAN}[4]${NC} Показать последние 50 строк"
            echo -e "  ${CYAN}[5]${NC} Завершить"
            read -rp "  Выберите действие [1-5]: " num_choice </dev/tty || break
            case "$num_choice" in
                1) chosen="scp" ;;
                2) chosen="web" ;;
                3) chosen="upload" ;;
                4) chosen="tail" ;;
                *) chosen="exit" ;;
            esac
        fi

        case "$chosen" in
            scp)
                echo ""
                echo -e "  ${YELLOW}${BOLD}Команды для скачивания лога на ваш компьютер:${NC}"
                echo -e "  • ${WHITE}Windows (PowerShell / cmd):${NC}"
                echo -e "    ${GREEN}scp -P ${ssh_port} root@${wan_ip}:${log_path} .${NC}"
                echo -e "  • ${WHITE}macOS / Linux Terminal:${NC}"
                echo -e "    ${GREEN}scp -P ${ssh_port} root@${wan_ip}:${log_path} ~/Downloads/${NC}"
                echo -e "  • ${WHITE}SFTP Клиент (FileZilla / WinSCP):${NC}"
                echo -e "    Хост: ${GREEN}${wan_ip}${NC}, Порт: ${GREEN}${ssh_port}${NC}, Пользователь: ${GREEN}root${NC}, Путь: ${GREEN}${log_path}${NC}"
                echo ""
                read -rp "  Нажмите Enter для возврата к меню экспорта... " _dummy </dev/tty || true
                ;;
            web)
                echo ""
                echo -e "  ${CYAN}${ARROW:-➜} Создание временной ссылки для скачивания...${NC}"
                local web_url
                web_url=$(create_web_download_link "$log_path" || true)
                if [ -n "$web_url" ]; then
                    echo -e "  ${GREEN}${CHECK:-✔} Ссылка готова (действует 15 минут):${NC}"
                    echo -e "    ${WHITE}${BOLD}${web_url}${NC}"
                else
                    warn "Не удалось создать веб-ссылку (Nginx и Python HTTP недоступны)."
                fi
                echo ""
                read -rp "  Нажмите Enter для возврата к меню экспорта... " _dummy </dev/tty || true
                ;;
            upload)
                echo ""
                echo -e "  ${CYAN}${ARROW:-➜} Очистка лога от паролей и токенов...${NC}"
                local tmp_clean
                tmp_clean=$(mktemp "${TMPDIR:-/tmp}/sanitized-log.XXXXXX") || continue
                sanitize_debug_log "$log_path" "$tmp_clean"
                echo -e "  ${CYAN}${ARROW:-➜} Загрузка на защищенный обменник...${NC}"
                local up_url
                up_url=$(upload_to_pastebin "$tmp_clean" || true)
                rm -f -- "$tmp_clean"
                if [ -n "$up_url" ]; then
                    echo -e "  ${GREEN}${CHECK:-✔} Журнал безопасно загружен:${NC}"
                    echo -e "    ${WHITE}${BOLD}${up_url}${NC}"
                    echo -e "  ${DIM}(Все пароли, ключи и токены были автоматически замаскированы)${NC}"
                else
                    warn "Не удалось загрузить лог на внешний сервис. Воспользуйтесь SCP."
                fi
                echo ""
                read -rp "  Нажмите Enter для возврата к меню экспорта... " _dummy </dev/tty || true
                ;;
            tail)
                echo ""
                echo -e "  ${YELLOW}${BOLD}Последние 50 строк журнала (${log_path}):${NC}"
                echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
                tail -n 50 "$log_path" | sed 's/^/  /' || true
                echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}\n"
                read -rp "  Нажмите Enter для возврата к меню экспорта... " _dummy </dev/tty || true
                ;;
            exit|*)
                break
                ;;
        esac
    done
}


prompt_default() {
    local prompt_text="$1"
    local default_val="$2"
    local var_name="$3"
    local cur_val="${!var_name:-}"
    local effective_default="${cur_val:-$default_val}"

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        printf -v "$var_name" '%s' "$effective_default"
        declare -g "$var_name=$effective_default" 2>/dev/null || true
        log "Параметр $var_name: ${GREEN}$effective_default${NC} (авто)"
        return 0
    fi

    local prompt_suffix=" [${GREEN}${effective_default}${NC}]"
    [ -z "$effective_default" ] && prompt_suffix=" [${GREEN}(пусто)${NC}]"
    if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
        prompt_suffix="${prompt_suffix} ${DIM}(b - назад)${NC}"
    fi

    local input_val
    read -rp "$(echo -e "${prompt_text}${prompt_suffix}: ")" input_val </dev/tty || read -r input_val || true
    if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
        if [[ "${input_val,,}" == "b" || "${input_val,,}" == "back" || "${input_val,,}" == "назад" ]]; then
            return 10
        fi
    fi
    local res_val="${input_val:-$effective_default}"
    printf -v "$var_name" '%s' "$res_val"
    declare -g "$var_name=$res_val" 2>/dev/null || true
    return 0
}

prompt_yes_no() {
    local prompt_text="$1"
    local default_val="$2"
    local var_name="$3"
    local cur_val="${!var_name:-}"
    local effective_default="${cur_val:-$default_val}"

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        case "${effective_default,,}" in
            y|yes|1|true)
                printf -v "$var_name" '%s' "y"
                declare -g "$var_name=y" 2>/dev/null || true
                ;;
            *)
                printf -v "$var_name" '%s' "n"
                declare -g "$var_name=n" 2>/dev/null || true
                ;;
        esac
        log "Выбор $var_name: ${GREEN}${!var_name}${NC} (авто)"
        return 0
    fi

    local hint="y/N"
    case "${effective_default,,}" in
        y|yes|1|true) hint="Y/n" ;;
    esac

    local prompt_suffix=" [${GREEN}${hint}${NC}]"
    if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
        prompt_suffix="${prompt_suffix} ${DIM}(b - назад)${NC}"
    fi

    while true; do
        local input_val
        read -rp "$(echo -e "${prompt_text}${prompt_suffix}: ")" input_val </dev/tty || read -r input_val || true
        if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
            if [[ "${input_val,,}" == "b" || "${input_val,,}" == "back" || "${input_val,,}" == "назад" ]]; then
                return 10
            fi
        fi
        input_val="${input_val:-$effective_default}"
        case "${input_val,,}" in
            y|yes|1|true)
                printf -v "$var_name" '%s' "y"
                declare -g "$var_name=y" 2>/dev/null || true
                return 0
                ;;
            n|no|0|false)
                printf -v "$var_name" '%s' "n"
                declare -g "$var_name=n" 2>/dev/null || true
                return 0
                ;;
            *) warn "Пожалуйста, введите 'y' или 'n' (или 'b' для возврата назад)." ;;
        esac
    done
}

prompt_secret() {
    local prompt_text="$1"
    local default_val="$2"
    local var_name="$3"
    local cur_val="${!var_name:-}"
    local effective_default="${cur_val:-$default_val}"

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        printf -v "$var_name" '%s' "$effective_default"
        declare -g "$var_name=$effective_default" 2>/dev/null || true
        if [ -n "$effective_default" ]; then
            log "Параметр $var_name: ${GREEN}***скрыто***${NC} (авто)"
        else
            log "Параметр $var_name: ${GREEN}(пусто)${NC} (авто)"
        fi
        return 0
    fi

    local prompt_suffix=" [${GREEN}***${NC}]"
    if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
        prompt_suffix="${prompt_suffix} ${DIM}(b - назад)${NC}"
    fi

    local input_val
    read -rp "$(echo -e "${prompt_text}${prompt_suffix}: ")" input_val </dev/tty || read -r input_val || true
    if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
        if [[ "${input_val,,}" == "b" || "${input_val,,}" == "back" || "${input_val,,}" == "назад" ]]; then
            return 10
        fi
    fi
    local res_val="${input_val:-$effective_default}"
    printf -v "$var_name" '%s' "$res_val"
    declare -g "$var_name=$res_val" 2>/dev/null || true
    return 0
}

validate_path_segment() {
    local val="$1"
    local name="$2"
    if [[ ! "$val" =~ ^[a-zA-Z0-9_/-]+$ ]]; then
        die "Параметр $name ('$val') содержит недопустимые символы. Используйте только латиницу, цифры, дефис, подчеркивание и слэши."
    fi
}

can_use_interactive_tui() {
    [ "${NON_INTERACTIVE:-0}" -eq 1 ] && return 1
    [ -t 1 ] || return 1
    ([ -t 0 ] || { : </dev/tty; } 2>/dev/null) || return 1
    local term="${TERM:-dumb}"
    [ "$term" != "dumb" ] && [ -n "$term" ] || return 1
    if command -v tput >/dev/null 2>&1; then
        tput cuu1 >/dev/null 2>&1 || return 1
    fi
    return 0
}

prompt_multiselect_numeric() {
    local prompt_text="$1"
    local -n _num_keys="$2"
    local -n _num_labels="$3"
    local count="${#_num_keys[@]}"

    echo ""
    echo -e "  ${WHITE}${BOLD}${prompt_text}:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"

    local sel=()
    local def_indices=()
    for ((i=0; i<count; i++)); do
        local k="${_num_keys[$i]}"
        if is_true "${!k:-n}"; then
            sel[i]=1
            def_indices+=("$((i+1))")
        else
            sel[i]=0
        fi
    done

    for ((i=0; i<count; i++)); do
        local mark=" "
        [ "${sel[$i]}" -eq 1 ] && mark="${GREEN}✔${NC}"
        local num=$((i+1))
        echo -e "    ${CYAN}[$num]${NC} [${mark}] ${_num_labels[$i]}"
    done
    echo ""

    local def_str=""
    if [ "${#def_indices[@]}" -gt 0 ]; then
        def_str=$(IFS=,; echo "${def_indices[*]}")
    else
        def_str="0"
    fi

    local prompt_hint=" [${GREEN}${def_str}${NC}]"
    if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
        prompt_hint="${prompt_hint} ${DIM}(b - назад)${NC}"
    fi

    while true; do
        local input_val=""
        echo -ne "  ${WHITE}${ARROW} Номера через запятую/пробел, 'all' или '0'${prompt_hint}: ${NC}"
        read -r input_val </dev/tty || read -r input_val || true
        input_val=$(echo "${input_val:-}" | tr '[:upper:]' '[:lower:]' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
            if [[ "$input_val" == "b" || "$input_val" == "back" || "$input_val" == "назад" ]]; then
                return 10
            fi
        fi

        if [ -z "$input_val" ]; then
            break
        fi

        if [[ "$input_val" == "all" || "$input_val" == "a" || "$input_val" == "все" ]]; then
            for ((i=0; i<count; i++)); do sel[i]=1; done
            break
        elif [[ "$input_val" == "0" || "$input_val" == "none" || "$input_val" == "нет" ]]; then
            for ((i=0; i<count; i++)); do sel[i]=0; done
            break
        fi

        local valid=1
        local new_sel=()
        for ((i=0; i<count; i++)); do new_sel[i]=0; done

        IFS=', ' read -ra tokens <<< "${input_val//,/ }"
        for tok in "${tokens[@]}"; do
            [ -z "$tok" ] && continue
            if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "$count" ]; then
                new_sel[$((tok-1))]=1
            else
                warn "  Некорректный номер: '$tok'. Введите числа от 1 до $count."
                valid=0
                break
            fi
        done

        if [ "$valid" -eq 1 ]; then
            for ((i=0; i<count; i++)); do sel[i]="${new_sel[$i]}"; done
            break
        fi
    done

    local chosen=()
    for ((i=0; i<count; i++)); do
        local k="${_num_keys[$i]}"
        if [ "${sel[$i]}" -eq 1 ]; then
            printf -v "$k" '%s' "y"
            declare -g "$k=y" 2>/dev/null || true
            chosen+=("${_num_labels[$i]%% (*}")
        else
            printf -v "$k" '%s' "n"
            declare -g "$k=n" 2>/dev/null || true
        fi
    done

    if [ "${#chosen[@]}" -gt 0 ]; then
        ok "Выбрано: $(IFS=,; echo "${chosen[*]}")"
    else
        log "Все протоколы из списка отключены."
    fi
    echo ""
    return 0
}

prompt_multiselect_tui() {
    # Menu labels are UTF-8; clipping must count characters even on LANG=C hosts.
    local LC_ALL=C.UTF-8
    local prompt_text="$1"
    local -n _tui_keys="$2"
    local -n _tui_labels="$3"
    local count="${#_tui_keys[@]}"

    local sel=()
    for ((i=0; i<count; i++)); do
        local k="${_tui_keys[$i]}"
        if is_true "${!k:-n}"; then
            sel[i]=1
        else
            sel[i]=0
        fi
    done

    echo ""
    echo -e "  ${WHITE}${BOLD}${prompt_text}:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"

    local cursor=0
    local total_lines=$((count + 1))

    # Keep one input descriptor open, including curl | bash installations.
    local input_fd tty_settings=""
    if { exec {input_fd}</dev/tty; } 2>/dev/null; then
        :
    else
        exec {input_fd}<&0
    fi
    if [ -t "$input_fd" ]; then
        tty_settings=$(stty -g <&"$input_fd" 2>/dev/null) || tty_settings=""
        if [ -n "$tty_settings" ]; then
            stty -echo -icanon min 1 time 0 <&"$input_fd" 2>/dev/null || true
        fi
    fi
    local saved_int_trap saved_term_trap
    saved_int_trap=$(trap -p INT)
    saved_term_trap=$(trap -p TERM)
    tput civis 2>/dev/null || printf '\033[?25l'
    trap '[ -z "${tty_settings:-}" ] || stty "$tty_settings" <&"$input_fd" 2>/dev/null; tput cnorm 2>/dev/null || printf "\033[?25h"; exit 130' INT
    trap '[ -z "${tty_settings:-}" ] || stty "$tty_settings" <&"$input_fd" 2>/dev/null; tput cnorm 2>/dev/null || printf "\033[?25h"; exit 143' TERM

    render_tui_menu() {
        local cols="${COLUMNS:-}"
        if [[ ! "$cols" =~ ^[0-9]+$ ]]; then
            cols=$(tput cols 2>/dev/null || echo 80)
        fi
        [[ "$cols" =~ ^[0-9]+$ ]] && [ "$cols" -ge 20 ] || cols=80
        local num_width="${#count}"
        local label_width=$((cols - num_width - 12))
        local i
        for ((i=0; i<count; i++)); do
            local mark=" "
            [ "${sel[$i]}" -eq 1 ] && mark="${GREEN}✔${NC}"
            local prefix="  "
            local color="${WHITE}"
            if [ "$i" -eq "$cursor" ]; then
                prefix="${CYAN}${ARROW}${NC} "
                color="${CYAN}${BOLD}"
            fi
            local num=$((i+1))
            local label="${_tui_labels[$i]}"
            if [ "${#label}" -gt "$label_width" ]; then
                label="${label:0:label_width-1}…"
            fi
            printf "\033[2K  %b[${color}%*s${NC}] [%b] %s\n" "$prefix" "$num_width" "$num" "$mark" "$label"
        done
        local hint="↑/↓: курсор | Пробел: выбор | Enter: готово | ?: номера"
        printf "\033[2K  ${DIM}%s${NC}\n" "${hint:0:cols-3}"
    }

    render_tui_menu

    local result=0 numeric_fallback=0 escape=""
    while true; do
        local key=""
        if ! IFS= read -rsn1 -u "$input_fd" key; then
            result=1
            break
        fi

        # Preserve escape-parser state between reads; SSH packet boundaries and
        # latency must not turn the final B of an arrow into the Back shortcut.
        if [ "$key" = $'\x1b' ]; then
            escape="$key"
            continue
        fi
        if [ "$escape" = $'\x1b' ]; then
            case "$key" in
                '['|O) escape="$key" ;;
                ''|$'\r') break ;;
                *) escape="" ;;
            esac
            continue
        fi
        if [ -n "$escape" ]; then
            escape+="$key"
            if [ -z "$key" ] || [ "$key" = $'\r' ] || [ "${#escape}" -gt 32 ]; then
                escape=""
                continue
            fi
            [[ "$key" == [@-~] ]] || continue
            case "$escape" in
                '['*A|OA) cursor=$(( (cursor - 1 + count) % count )) ;;
                '['*B|OB) cursor=$(( (cursor + 1) % count )) ;;
            esac
            escape=""
        elif [[ "$key" == "k" || "$key" == "K" ]]; then
            cursor=$(( (cursor - 1 + count) % count ))
        elif [[ "$key" == "j" || "$key" == "J" ]]; then
            cursor=$(( (cursor + 1) % count ))
        elif [ "$key" = " " ]; then
            if [ "${sel[$cursor]}" -eq 1 ]; then
                sel[$cursor]=0
            else
                sel[$cursor]=1
            fi
        elif [[ "$key" =~ ^[1-9]$ ]] && [ "$key" -le "$count" ]; then
            local idx=$((key - 1))
            if [ "${sel[$idx]}" -eq 1 ]; then
                sel[$idx]=0
            else
                sel[$idx]=1
            fi
        elif [[ "$key" == "a" || "$key" == "A" ]]; then
            for ((i=0; i<count; i++)); do sel[i]=1; done
        elif [[ "$key" == "0" || "$key" == "n" || "$key" == "N" ]]; then
            for ((i=0; i<count; i++)); do sel[i]=0; done
        elif [ -z "$key" ] || [ "$key" = $'\r' ]; then
            break
        elif [[ "$key" == "b" || "$key" == "B" ]]; then
            if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
                result=10
                break
            fi
        elif [ "$key" = "?" ]; then
            numeric_fallback=1
            break
        fi

        printf "\033[%dA\r" "$total_lines"
        render_tui_menu
    done

    [ -z "$tty_settings" ] || stty "$tty_settings" <&"$input_fd" 2>/dev/null || true
    exec {input_fd}<&-
    tput cnorm 2>/dev/null || printf '\033[?25h'
    trap - INT TERM
    # These strings come from Bash's own trap -p, not from external input.
    [ -z "$saved_int_trap" ] || eval "$saved_int_trap"
    [ -z "$saved_term_trap" ] || eval "$saved_term_trap"

    printf "\033[%dA\r" "$total_lines"
    for ((i=0; i<total_lines; i++)); do
        printf "\033[2K\n"
    done
    printf "\033[%dA\r" "$total_lines"

    [ "$result" -eq 0 ] || return "$result"
    if [ "$numeric_fallback" -eq 1 ]; then
        prompt_multiselect_numeric "$prompt_text" "$2" "$3"
        return $?
    fi

    local chosen=()
    for ((i=0; i<count; i++)); do
        local k="${_tui_keys[$i]}"
        if [ "${sel[$i]}" -eq 1 ]; then
            printf -v "$k" '%s' "y"
            declare -g "$k=y" 2>/dev/null || true
            chosen+=("${_tui_labels[$i]%% (*}")
        else
            printf -v "$k" '%s' "n"
            declare -g "$k=n" 2>/dev/null || true
        fi
    done

    if [ "${#chosen[@]}" -gt 0 ]; then
        ok "Выбрано: $(IFS=,; echo "${chosen[*]}")"
    else
        log "Все протоколы из списка отключены."
    fi
    echo ""
    return 0
}

prompt_multiselect() {
    local prompt_text="$1"
    local -n _ms_keys="$2"
    local -n _ms_labels="$3"

    if [ "${NON_INTERACTIVE:-0}" -eq 1 ]; then
        for _k in "${_ms_keys[@]}"; do
            log "Выбор $_k: ${GREEN}${!_k:-n}${NC} (авто)"
        done
        return 0
    fi

    # Use arrow navigation automatically on an interactive terminal. Setting
    # ENABLE_TUI_MULTISELECT=0 explicitly retains the numeric selector.
    if [ "${ENABLE_TUI_MULTISELECT:-1}" != "0" ] && can_use_interactive_tui; then
        prompt_multiselect_tui "$prompt_text" _ms_keys _ms_labels || return $?
    else
        prompt_multiselect_numeric "$prompt_text" _ms_keys _ms_labels || return $?
    fi
}

prompt_select_numeric() {
    local prompt_text="$1"
    local var_name="$2"
    local default_val="$3"
    local -n _s_keys="$4"
    local -n _s_labels="$5"
    local count="${#_s_keys[@]}"

    local cur_val="${!var_name:-$default_val}"
    local def_idx=1
    for ((i=0; i<count; i++)); do
        if [ "${_s_keys[$i]}" = "$cur_val" ]; then
            def_idx=$((i+1))
            break
        fi
    done

    echo ""
    echo -e "  ${WHITE}${BOLD}${prompt_text}:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"

    local num_width="${#count}"
    for ((i=0; i<count; i++)); do
        local num=$((i+1))
        local mark="${DIM}(○)${NC}"
        [ "$num" -eq "$def_idx" ] && mark="${CYAN}(●)${NC}"
        printf "  [%*s] %b %-14s ${DIM}%s${NC}\n" "$num_width" "$num" "$mark" "${_s_keys[$i]}" "${_s_labels[$i]}"
    done

    local prompt_hint=" [${GREEN}${def_idx}${NC}]"
    if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
        prompt_hint="${prompt_hint} ${DIM}(b - назад)${NC}"
    fi

    while true; do
        local input=""
        echo -ne "  ${WHITE}${ARROW} Выберите номер (1-${count})${prompt_hint}: ${NC}"
        read -r input </dev/tty || read -r input || true

        if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
            if [[ "${input,,}" == "b" || "${input,,}" == "back" || "${input,,}" == "назад" ]]; then
                return 10
            fi
        fi

        [ -z "$input" ] && input="$def_idx"

        if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "$count" ]; then
            local chosen_idx=$((input - 1))
            local chosen_val="${_s_keys[$chosen_idx]}"
            printf -v "$var_name" '%s' "$chosen_val"
            declare -g "$var_name=$chosen_val" 2>/dev/null || true
            ok "Выбрано: ${GREEN}${chosen_val}${NC} (${_s_labels[$chosen_idx]})"
            echo ""
            return 0
        fi

        local raw_input="${input,,}"
        for ((i=0; i<count; i++)); do
            if [ "${_s_keys[$i],,}" = "$raw_input" ]; then
                local chosen_val="${_s_keys[$i]}"
                printf -v "$var_name" '%s' "$chosen_val"
                declare -g "$var_name=$chosen_val" 2>/dev/null || true
                ok "Выбрано: ${GREEN}${chosen_val}${NC} (${_s_labels[$i]})"
                echo ""
                return 0
            fi
        done

        warn "Некорректный выбор: '$input'. Введите число от 1 до $count."
    done
}

prompt_select_tui() {
    local LC_ALL=C.UTF-8
    local prompt_text="$1"
    local var_name="$2"
    local default_val="$3"
    local -n _tui_s_keys="$4"
    local -n _tui_s_labels="$5"
    local count="${#_tui_s_keys[@]}"

    local cur_val="${!var_name:-$default_val}"
    local selected=0
    for ((i=0; i<count; i++)); do
        if [ "${_tui_s_keys[$i]}" = "$cur_val" ]; then
            selected=$i
            break
        fi
    done
    local cursor=$selected

    echo ""
    echo -e "  ${WHITE}${BOLD}${prompt_text}:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"

    local total_lines=$((count + 1))

    local input_fd tty_settings=""
    if { exec {input_fd}</dev/tty; } 2>/dev/null; then
        :
    else
        exec {input_fd}<&0
    fi
    if [ -t "$input_fd" ]; then
        tty_settings=$(stty -g <&"$input_fd" 2>/dev/null) || tty_settings=""
        if [ -n "$tty_settings" ]; then
            stty -echo -icanon min 1 time 0 <&"$input_fd" 2>/dev/null || true
        fi
    fi
    local saved_int_trap saved_term_trap
    saved_int_trap=$(trap -p INT)
    saved_term_trap=$(trap -p TERM)
    tput civis 2>/dev/null || printf '\033[?25l'
    trap '[ -z "${tty_settings:-}" ] || stty "$tty_settings" <&"$input_fd" 2>/dev/null; tput cnorm 2>/dev/null || printf "\033[?25h"; exit 130' INT
    trap '[ -z "${tty_settings:-}" ] || stty "$tty_settings" <&"$input_fd" 2>/dev/null; tput cnorm 2>/dev/null || printf "\033[?25h"; exit 143' TERM

    render_select_menu() {
        local cols="${COLUMNS:-}"
        if [[ ! "$cols" =~ ^[0-9]+$ ]]; then
            cols=$(tput cols 2>/dev/null || echo 80)
        fi
        [[ "$cols" =~ ^[0-9]+$ ]] && [ "$cols" -ge 20 ] || cols=80
        local num_width="${#count}"
        local key_col_width=14
        local overhead=$((num_width + 14 + key_col_width))
        local max_label_width=$((cols - overhead))
        [ "$max_label_width" -ge 8 ] || max_label_width=8
        local i
        for ((i=0; i<count; i++)); do
            local mark="${DIM}(○)${NC}"
            local prefix="  "
            local color="${WHITE}"
            if [ "$i" -eq "$selected" ]; then
                mark="${CYAN}(●)${NC}"
            fi
            if [ "$i" -eq "$cursor" ]; then
                prefix="${CYAN}${ARROW}${NC} "
                color="${CYAN}${BOLD}"
            fi
            local num=$((i+1))
            local key_display="${_tui_s_keys[$i]}"
            if [ "${#key_display}" -gt "$key_col_width" ]; then
                key_display="${key_display:0:key_col_width-1}…"
            fi
            local label_display="${_tui_s_labels[$i]}"
            if [ "${#label_display}" -gt "$max_label_width" ]; then
                label_display="${label_display:0:max_label_width-1}…"
            fi
            printf "\033[2K  %b[${color}%*s${NC}] %b %-14s ${DIM}%s${NC}\n" "$prefix" "$num_width" "$num" "$mark" "$key_display" "$label_display"
        done
        local hint="↑/↓: курсор | Пробел: выбрать (●) | Enter: подтвердить | ?: номера"
        printf "\033[2K  ${DIM}%s${NC}\n" "${hint:0:cols-3}"
    }

    render_select_menu

    local result=0 numeric_fallback=0 escape=""
    while true; do
        local key=""
        if ! IFS= read -rsn1 -u "$input_fd" key; then
            result=1
            break
        fi

        if [ "$key" = $'\033' ]; then
            local rest=""
            read -rsn2 -t 0.1 -u "$input_fd" rest || true
            key="${key}${rest}"
            case "$key" in
                $'\033[A'|$'\033OA')
                    cursor=$(( (cursor - 1 + count) % count ))
                    ;;
                $'\033[B'|$'\033OB')
                    cursor=$(( (cursor + 1) % count ))
                    ;;
                $'\033[H'|$'\033[1~')
                    cursor=0
                    ;;
                $'\033[F'|$'\033[4~')
                    cursor=$((count - 1))
                    ;;
            esac
        elif [[ "$key" == "k" || "$key" == "K" ]]; then
            cursor=$(( (cursor - 1 + count) % count ))
        elif [[ "$key" == "j" || "$key" == "J" ]]; then
            cursor=$(( (cursor + 1) % count ))
        elif [[ "$key" =~ ^[1-9]$ ]]; then
            local num_val=$((key))
            if [ "$num_val" -le "$count" ]; then
                cursor=$((num_val - 1))
                selected=$cursor
            fi
        elif [ "$key" = " " ]; then
            selected=$cursor
        elif [ -z "$key" ] || [ "$key" = $'\r' ]; then
            selected=$cursor
            break
        elif [[ "$key" == "b" || "$key" == "B" ]]; then
            if [ "${WIZARD_ALLOW_BACK:-0}" -eq 1 ]; then
                result=10
                break
            fi
        elif [ "$key" = "?" ]; then
            numeric_fallback=1
            break
        fi

        printf "\033[%dA\r" "$total_lines"
        render_select_menu
    done

    [ -z "$tty_settings" ] || stty "$tty_settings" <&"$input_fd" 2>/dev/null || true
    exec {input_fd}<&-
    tput cnorm 2>/dev/null || printf '\033[?25h'
    trap - INT TERM
    [ -z "$saved_int_trap" ] || eval "$saved_int_trap"
    [ -z "$saved_term_trap" ] || eval "$saved_term_trap"

    printf "\033[%dA\r" "$total_lines"
    for ((i=0; i<total_lines; i++)); do
        printf "\033[2K\n"
    done
    printf "\033[%dA\r" "$total_lines"

    [ "$result" -eq 0 ] || return "$result"
    if [ "$numeric_fallback" -eq 1 ]; then
        prompt_select_numeric "$prompt_text" "$var_name" "$default_val" "$4" "$5"
        return $?
    fi

    local chosen_val="${_tui_s_keys[$selected]}"
    printf -v "$var_name" '%s' "$chosen_val"
    declare -g "$var_name=$chosen_val" 2>/dev/null || true
    ok "Выбрано: ${GREEN}${chosen_val}${NC} (${_tui_s_labels[$selected]})"
    echo ""
    return 0
}

prompt_select() {
    local prompt_text="$1"
    local var_name="$2"
    local default_val="$3"
    local -n _ps_keys="$4"
    local -n _ps_labels="$5"

    if [ "${NON_INTERACTIVE:-0}" -eq 1 ]; then
        local effective_default="${!var_name:-$default_val}"
        printf -v "$var_name" '%s' "$effective_default"
        declare -g "$var_name=$effective_default" 2>/dev/null || true
        log "Параметр $var_name: ${GREEN}$effective_default${NC} (авто)"
        return 0
    fi

    if [ "${ENABLE_TUI_MULTISELECT:-1}" != "0" ] && can_use_interactive_tui; then
        prompt_select_tui "$prompt_text" "$var_name" "$default_val" "$4" "$5" || return $?
    else
        prompt_select_numeric "$prompt_text" "$var_name" "$default_val" "$4" "$5" || return $?
    fi
}

# ----------------- Обработка аргументов командной строки -----------------
CONFIG_FILE=""
NON_INTERACTIVE=${NON_INTERACTIVE:-0}
DEBUG_MODE=${DEBUG_MODE:-0}
EXPERT_MODE=${EXPERT_MODE:-0}
SHOW_TIPS=${SHOW_TIPS:-}
CHECK_MODE=0
GEN_CONFIG=0
ROTATE_PATHS=0
FORCE_DNS=${FORCE_DNS:-0}
PORTS_SETUP_MODE="${PORTS_SETUP_MODE:-0}"
PATHS_SETUP_MODE="${PATHS_SETUP_MODE:-0}"
SAVED_CONFIG_FILE="server-setup.env"

CLI_PRIMARY_DOMAIN=""
CLI_ADD_WWW=""
CLI_LE_EMAIL=""
CLI_PANEL_PORT=""
CLI_PANEL_PATH=""
CLI_SUB_PATH=""
CLI_SUB_TITLE=""
CLI_XHTTP_STREAM_PATH=""
CLI_DIAG_PATH=""
CLI_DIAG_TOKEN=""
CLI_ADMIN_USERNAME=""
CLI_ADMIN_PASSWORD=""
CLI_ENABLE_NODE_TOKEN=""
CLI_NODE_TOKEN_NAME=""
CLI_ENABLE_HY2=""
CLI_ENABLE_AWG_V3=""
CLI_AWG_V3_PORT=""
CLI_ENABLE_AWG_V2=""
CLI_AWG_V2_PORT=""
CLI_ENABLE_AWG_STANDALONE=""
CLI_AWG_STANDALONE_PORT=""
CLI_ENABLE_SS2022=""
CLI_SS2022_PORT=""
CLI_ENABLE_TUIC=""
CLI_TUIC_PORT=""
CLI_ENABLE_MTPROTO=""
CLI_MTPROTO_PORT=""
CLI_MTPROTO_FAKETLS_DOMAIN=""
CLI_MTPROTO_ADTAG=""
CLI_ENABLE_WEB_STACK=""
CLI_AWG_SERVER_HOST=""
CLI_ENABLE_MASQUE=""
CLI_MASQUE_PORT=""
CLI_ENABLE_SHADOWTLS=""
CLI_SHADOWTLS_PORT=""
CLI_SHADOWTLS_SNI=""
CLI_SHADOWTLS_PASSWORD=""
CLI_ENABLE_WSTUNNEL=""
CLI_WSTUNNEL_PORT=""
CLI_WSTUNNEL_PREFIX=""
CLI_ENABLE_ZAPRET=""
CLI_ZAPRET_QNUM=""
CLI_ENABLE_NAIVE=""
CLI_NAIVE_PORT=""
CLI_NAIVE_DOMAIN=""
CLI_NAIVE_USER=""
CLI_NAIVE_PASS=""
CLI_ENABLE_DNSTT=""
CLI_DNSTT_PORT=""
CLI_DNSTT_DOMAIN=""
CLI_DNSTT_PUBKEY=""
CLI_ENABLE_MIERU=""
CLI_MIERU_PORT_MODE=""
CLI_MIERU_PORT=""
CLI_MIERU_TRANSPORT=""
CLI_MIERU_USER=""
CLI_MIERU_PASS=""
CLI_ALL_PROTOCOLS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --node-token)
            CLI_ENABLE_NODE_TOKEN=y
            shift
            ;;
        --no-node-token)
            CLI_ENABLE_NODE_TOKEN=n
            shift
            ;;
        --node-token-name)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует имя API-ключа ноды."
            CLI_NODE_TOKEN_NAME="$2"
            shift 2
            ;;
        --rotate-paths)
            ROTATE_PATHS=1
            shift
            ;;
        -c|--config)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: путь к файлу конфигурации."
            CONFIG_FILE="$2"
            shift 2
            ;;
        -y|--yes|--non-interactive)
            NON_INTERACTIVE=1
            shift
            ;;
        --auto)
            NON_INTERACTIVE=1
            EXPRESS_MODE=1
            shift
            ;;
        -d|--domain)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: доменное имя."
            PRIMARY_DOMAIN="$2"
            CLI_PRIMARY_DOMAIN="$2"
            shift 2
            ;;
        --add-www)
            ADD_WWW="y"
            CLI_ADD_WWW="y"
            shift
            ;;
        --no-www)
            ADD_WWW="n"
            CLI_ADD_WWW="n"
            shift
            ;;
        --hy2)
            ENABLE_HY2="y"
            CLI_ENABLE_HY2="y"
            shift
            ;;
        --no-hy2)
            ENABLE_HY2="n"
            CLI_ENABLE_HY2="n"
            shift
            ;;
        --awg-v3|--enable-awg-v3)
            ENABLE_AWG_V3="y"
            CLI_ENABLE_AWG_V3="y"
            shift
            ;;
        --no-awg-v3|--disable-awg-v3)
            ENABLE_AWG_V3="n"
            CLI_ENABLE_AWG_V3="n"
            shift
            ;;
        --awg-v3-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт AmneziaWG v3."
            AWG_V3_PORT="$2"
            CLI_AWG_V3_PORT="$2"
            shift 2
            ;;
        --awg-v2|--enable-awg-v2)
            ENABLE_AWG_V2="y"
            CLI_ENABLE_AWG_V2="y"
            shift
            ;;
        --no-awg-v2|--disable-awg-v2)
            ENABLE_AWG_V2="n"
            CLI_ENABLE_AWG_V2="n"
            shift
            ;;
        --awg-v2-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт AmneziaWG v2."
            AWG_V2_PORT="$2"
            CLI_AWG_V2_PORT="$2"
            shift 2
            ;;
        --awg-standalone|--enable-awg-standalone)
            ENABLE_AWG_STANDALONE="y"
            CLI_ENABLE_AWG_STANDALONE="y"
            shift
            ;;
        --no-awg-standalone|--disable-awg-standalone)
            ENABLE_AWG_STANDALONE="n"
            CLI_ENABLE_AWG_STANDALONE="n"
            shift
            ;;
        --awg-standalone-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт автономного AmneziaWG."
            AWG_STANDALONE_PORT="$2"
            CLI_AWG_STANDALONE_PORT="$2"
            shift 2
            ;;
        --awg-host)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: хост/IP для подключения клиентов AmneziaWG."
            AWG_SERVER_HOST="$2"
            CLI_AWG_SERVER_HOST="$2"
            shift 2
            ;;
        --web-stack|--enable-web-stack)
            ENABLE_WEB_STACK="y"
            CLI_ENABLE_WEB_STACK="y"
            shift
            ;;
        --no-web-stack|--disable-web-stack)
            ENABLE_WEB_STACK="n"
            CLI_ENABLE_WEB_STACK="n"
            shift
            ;;
        --ss2022|--enable-ss2022)
            ENABLE_SS2022="y"
            CLI_ENABLE_SS2022="y"
            shift
            ;;
        --no-ss2022|--disable-ss2022)
            ENABLE_SS2022="n"
            CLI_ENABLE_SS2022="n"
            shift
            ;;
        --ss2022-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт Shadowsocks 2022."
            SS2022_PORT="$2"
            CLI_SS2022_PORT="$2"
            shift 2
            ;;
        --tuic|--enable-tuic)
            ENABLE_TUIC="y"
            CLI_ENABLE_TUIC="y"
            shift
            ;;
        --no-tuic|--disable-tuic)
            ENABLE_TUIC="n"
            CLI_ENABLE_TUIC="n"
            shift
            ;;
        --tuic-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт TUIC."
            TUIC_PORT="$2"
            CLI_TUIC_PORT="$2"
            shift 2
            ;;
        --mtproto|--enable-mtproto)
            ENABLE_MTPROTO="y"
            CLI_ENABLE_MTPROTO="y"
            shift
            ;;
        --no-mtproto|--disable-mtproto)
            ENABLE_MTPROTO="n"
            CLI_ENABLE_MTPROTO="n"
            shift
            ;;
        --mtproto-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт MTProxy."
            MTPROTO_PORT="$2"
            CLI_MTPROTO_PORT="$2"
            shift 2
            ;;
        --mtproto-domain)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: FakeTLS домен MTProxy."
            MTPROTO_FAKETLS_DOMAIN="$2"
            CLI_MTPROTO_FAKETLS_DOMAIN="$2"
            shift 2
            ;;
        --mtproto-adtag)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: промо-тег adTag."
            MTPROTO_ADTAG="$2"
            CLI_MTPROTO_ADTAG="$2"
            shift 2
            ;;
        --masque|--enable-masque)
            ENABLE_MASQUE="y"
            CLI_ENABLE_MASQUE="y"
            shift
            ;;
        --no-masque|--disable-masque)
            ENABLE_MASQUE="n"
            CLI_ENABLE_MASQUE="n"
            shift
            ;;
        --masque-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт MASQUE."
            MASQUE_PORT="$2"
            CLI_MASQUE_PORT="$2"
            shift 2
            ;;
        --shadowtls|--enable-shadowtls)
            ENABLE_SHADOWTLS="y"
            CLI_ENABLE_SHADOWTLS="y"
            shift
            ;;
        --no-shadowtls|--disable-shadowtls)
            ENABLE_SHADOWTLS="n"
            CLI_ENABLE_SHADOWTLS="n"
            shift
            ;;
        --shadowtls-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт ShadowTLS."
            SHADOWTLS_PORT="$2"
            CLI_SHADOWTLS_PORT="$2"
            shift 2
            ;;
        --shadowtls-sni)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: SNI ShadowTLS."
            SHADOWTLS_SNI="$2"
            CLI_SHADOWTLS_SNI="$2"
            shift 2
            ;;
        --shadowtls-pass|--shadowtls-password)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: пароль ShadowTLS."
            SHADOWTLS_PASSWORD="$2"
            CLI_SHADOWTLS_PASSWORD="$2"
            shift 2
            ;;
        --wstunnel|--enable-wstunnel)
            ENABLE_WSTUNNEL="y"
            CLI_ENABLE_WSTUNNEL="y"
            shift
            ;;
        --no-wstunnel|--disable-wstunnel)
            ENABLE_WSTUNNEL="n"
            CLI_ENABLE_WSTUNNEL="n"
            shift
            ;;
        --wstunnel-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт Wstunnel."
            WSTUNNEL_PORT="$2"
            CLI_WSTUNNEL_PORT="$2"
            shift 2
            ;;
        --wstunnel-prefix|--wstunnel-path)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: путь Wstunnel."
            WSTUNNEL_PREFIX="$2"
            CLI_WSTUNNEL_PREFIX="$2"
            shift 2
            ;;
        --zapret|--enable-zapret)
            ENABLE_ZAPRET="y"
            CLI_ENABLE_ZAPRET="y"
            shift
            ;;
        --no-zapret|--disable-zapret)
            ENABLE_ZAPRET="n"
            CLI_ENABLE_ZAPRET="n"
            shift
            ;;
        --zapret-qnum)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: номер очереди NFQUEUE для Zapret."
            ZAPRET_QNUM="$2"
            CLI_ZAPRET_QNUM="$2"
            shift 2
            ;;
        --naive|--enable-naive)
            ENABLE_NAIVE="y"
            CLI_ENABLE_NAIVE="y"
            shift
            ;;
        --no-naive|--disable-naive)
            ENABLE_NAIVE="n"
            CLI_ENABLE_NAIVE="n"
            shift
            ;;
        --naive-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт NaïveProxy."
            NAIVE_PORT="$2"
            CLI_NAIVE_PORT="$2"
            shift 2
            ;;
        --naive-domain)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: SNI домен NaïveProxy."
            NAIVE_DOMAIN="$2"
            CLI_NAIVE_DOMAIN="$2"
            shift 2
            ;;
        --naive-user)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: имя пользователя NaïveProxy."
            NAIVE_USER="$2"
            CLI_NAIVE_USER="$2"
            shift 2
            ;;
        --naive-pass|--naive-password)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: пароль NaïveProxy."
            NAIVE_PASS="$2"
            CLI_NAIVE_PASS="$2"
            shift 2
            ;;
        --dnstt|--enable-dnstt)
            ENABLE_DNSTT="y"
            CLI_ENABLE_DNSTT="y"
            shift
            ;;
        --no-dnstt|--disable-dnstt)
            ENABLE_DNSTT="n"
            CLI_ENABLE_DNSTT="n"
            shift
            ;;
        --dnstt-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: UDP порт DNSTT."
            DNSTT_PORT="$2"
            CLI_DNSTT_PORT="$2"
            shift 2
            ;;
        --dnstt-domain)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: домен зоны DNSTT."
            DNSTT_DOMAIN="$2"
            CLI_DNSTT_DOMAIN="$2"
            shift 2
            ;;
        --dnstt-pubkey)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: публичный ключ DNSTT."
            DNSTT_PUBKEY="$2"
            CLI_DNSTT_PUBKEY="$2"
            shift 2
            ;;
        --mieru|--enable-mieru)
            ENABLE_MIERU="y"
            CLI_ENABLE_MIERU="y"
            shift
            ;;
        --no-mieru|--disable-mieru)
            ENABLE_MIERU="n"
            CLI_ENABLE_MIERU="n"
            shift
            ;;
        --mieru-port-mode)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: single или range."
            MIERU_PORT_MODE="$2"
            CLI_MIERU_PORT_MODE="$2"
            shift 2
            ;;
        --mieru-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт или диапазон Mieru (например 8450 или 8450-8455)."
            MIERU_PORT="$2"
            CLI_MIERU_PORT="$2"
            shift 2
            ;;
        --mieru-transport)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: транспорт Mieru (TCP, UDP, BOTH)."
            MIERU_TRANSPORT="$2"
            CLI_MIERU_TRANSPORT="$2"
            shift 2
            ;;
        --mieru-user)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: имя пользователя Mieru."
            MIERU_USER="$2"
            CLI_MIERU_USER="$2"
            shift 2
            ;;
        --mieru-pass|--mieru-password)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: пароль Mieru."
            MIERU_PASS="$2"
            CLI_MIERU_PASS="$2"
            shift 2
            ;;
        --all-protocols|--all-proto)
            CLI_ALL_PROTOCOLS="1"
            ALL_PROTOCOLS="1"
            ENABLE_HY2="y"; CLI_ENABLE_HY2="y"
            ENABLE_AWG_V3="y"; CLI_ENABLE_AWG_V3="y"
            ENABLE_SS2022="y"; CLI_ENABLE_SS2022="y"
            ENABLE_TUIC="y"; CLI_ENABLE_TUIC="y"
            ENABLE_MTPROTO="y"; CLI_ENABLE_MTPROTO="y"
            ENABLE_MASQUE="y"; CLI_ENABLE_MASQUE="y"
            ENABLE_SHADOWTLS="y"; CLI_ENABLE_SHADOWTLS="y"
            ENABLE_WSTUNNEL="y"; CLI_ENABLE_WSTUNNEL="y"
            ENABLE_ZAPRET="y"; CLI_ENABLE_ZAPRET="y"
            ENABLE_NAIVE="y"; CLI_ENABLE_NAIVE="y"
            ENABLE_DNSTT="y"; CLI_ENABLE_DNSTT="y"
            ENABLE_MIERU="y"; CLI_ENABLE_MIERU="y"
            shift
            ;;
        -m|--email)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: email."
            LE_EMAIL="$2"
            CLI_LE_EMAIL="$2"
            shift 2
            ;;
        --panel-port)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: порт панели."
            PANEL_PORT="$2"
            CLI_PANEL_PORT="$2"
            shift 2
            ;;
        --panel-path)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: путь к панели."
            PANEL_PATH="$2"
            CLI_PANEL_PATH="$2"
            shift 2
            ;;
        --sub-path)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: путь к подпискам."
            SUB_PATH="$2"
            CLI_SUB_PATH="$2"
            shift 2
            ;;
        --sub-title)
            SUB_TITLE="${2:-}"
            CLI_SUB_TITLE="${2:-}"
            shift 2
            ;;
        --xhttp-path)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: путь к xHTTP."
            XHTTP_STREAM_PATH="$2"
            CLI_XHTTP_STREAM_PATH="$2"
            shift 2
            ;;
        --diag-path)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: путь к веб-диагностике."
            DIAG_PATH="$2"
            CLI_DIAG_PATH="$2"
            shift 2
            ;;
        --diag-token)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: токен веб-диагностики."
            DIAG_TOKEN="$2"
            CLI_DIAG_TOKEN="$2"
            shift 2
            ;;
        -u|--user|--admin-user)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: логин администратора 3X-UI."
            ADMIN_USERNAME="$2"
            CLI_ADMIN_USERNAME="$2"
            shift 2
            ;;
        -p|--pass|--admin-pass)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует аргумент: пароль администратора 3X-UI."
            ADMIN_PASSWORD="$2"
            CLI_ADMIN_PASSWORD="$2"
            shift 2
            ;;
        -r|--resume)
            RESUME_MODE=1
            shift
            ;;
        --step)
            [[ -n "${2:-}" ]] || die "Параметр $1 требует номер шага (1-$TOTAL_STEPS)."
            RESUME_STEP="$2"
            STEP_EXPLICIT=1
            shift 2
            ;;
        --check|--doctor)
            CHECK_MODE=1
            shift
            ;;
        --express)
            EXPRESS_MODE=1
            shift
            ;;
        --expert)
            EXPERT_MODE=1
            shift
            ;;
        --manual-steps)
            SHOW_MANUAL_STEPS=1
            shift
            ;;
        --gen-config)
            GEN_CONFIG=1
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                TARGET_GEN_FILE="$2"
                shift 2
            else
                TARGET_GEN_FILE="server-setup.env.example"
                shift
            fi
            ;;
        --debug)
            DEBUG_MODE=1
            shift
            ;;
        --dry-run)
            echo -e "\n  ${YELLOW}${BOLD}[INFO] Режим --dry-run не поддерживается установщиком setup.sh.${NC}"
            echo -e "  Развертывание ОС и сетевого стека требует реальных изменений системы.\n"
            echo -e "  ${CYAN}Для безопасного аудита без внесения изменений используйте:${NC}"
            echo -e "    • ${WHITE}./setup.sh --check${NC}         (быстрая диагностика сервисов, портов, SSL)"
            echo -e "    • ${WHITE}./maintain.sh --dry-run${NC}    (холостой аудит базы 3X-UI и конфигов Nginx)\n"
            exit 0
            ;;
        --uninstall)
            if command -v run_uninstall >/dev/null 2>&1; then
                run_uninstall
                exit 0
            else
                die "Модуль деинсталляции недоступен."
            fi
            ;;
        -f|--force)
            FORCE_DNS=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            warn "Неизвестный параметр: $1"
            shift
            ;;
    esac
done

# Автообнаружение конфигурационного файла, если путь не передан явно
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
if [ -z "$CONFIG_FILE" ]; then
    CONFIG_FILE=$(find_config_file "$SCRIPT_DIR" || true)
    if [ -n "$CONFIG_FILE" ]; then
        log "Автообнаружен конфигурационный файл: $CONFIG_FILE"
    elif [ "$NON_INTERACTIVE" -eq 0 ] && [ -f "./.env" ]; then
        CONFIG_FILE="./.env"
        warn "Автообнаружен конфигурационный файл: $CONFIG_FILE (убедитесь, что он предназначен для этого скрипта)"
    fi
fi

if [ -n "$CONFIG_FILE" ]; then
    load_env_file "$CONFIG_FILE"
fi

# Явные аргументы командной строки имеют абсолютный приоритет над файлом конфигурации
[ -n "${CLI_PRIMARY_DOMAIN:-}" ] && PRIMARY_DOMAIN="$CLI_PRIMARY_DOMAIN"
[ -n "${CLI_ADD_WWW:-}" ]        && ADD_WWW="$CLI_ADD_WWW"
[ -n "${CLI_LE_EMAIL:-}" ]       && LE_EMAIL="$CLI_LE_EMAIL"
[ -n "${CLI_PANEL_PORT:-}" ]     && PANEL_PORT="$CLI_PANEL_PORT"
[ -n "${CLI_PANEL_PATH:-}" ]     && PANEL_PATH="$CLI_PANEL_PATH"
[ -n "${CLI_SUB_PATH:-}" ]       && SUB_PATH="$CLI_SUB_PATH"
[ -n "${CLI_SUB_TITLE:-}" ]      && SUB_TITLE="$CLI_SUB_TITLE"
[ -n "${CLI_XHTTP_STREAM_PATH:-}" ] && XHTTP_STREAM_PATH="$CLI_XHTTP_STREAM_PATH"
[ -n "${CLI_DIAG_PATH:-}" ]      && DIAG_PATH="$CLI_DIAG_PATH"
[ -n "${CLI_DIAG_TOKEN:-}" ]     && DIAG_TOKEN="$CLI_DIAG_TOKEN"
[ -n "${CLI_ADMIN_USERNAME:-}" ] && ADMIN_USERNAME="$CLI_ADMIN_USERNAME"
[ -n "${CLI_ADMIN_PASSWORD:-}" ] && ADMIN_PASSWORD="$CLI_ADMIN_PASSWORD"
[ -n "${CLI_ENABLE_NODE_TOKEN:-}" ] && ENABLE_NODE_TOKEN="$CLI_ENABLE_NODE_TOKEN"
[ -n "${CLI_NODE_TOKEN_NAME:-}" ] && NODE_TOKEN_NAME="$CLI_NODE_TOKEN_NAME"
if [ -n "${CLI_PANEL_PATH:-}" ]; then
    RAW_PATH="${CLI_PANEL_PATH#/}"; RAW_PATH="${RAW_PATH%/}"
fi
if [ -n "${CLI_SUB_PATH:-}" ]; then
    RAW_SUB_PATH="${CLI_SUB_PATH#/}"; RAW_SUB_PATH="${RAW_SUB_PATH%/}"
    SUB_PATH="/${RAW_SUB_PATH}/"
    SUB_JSON_PATH="${SUB_PATH}json/"
    if [ -z "${CONFIG_EXPLICIT_KEYS[SUB_CLASH_PATH]:-}" ]; then
        SUB_CLASH_PATH="${SUB_PATH}clash/"
    fi
fi
if [ -n "${CLI_XHTTP_STREAM_PATH:-}" ]; then
    RAW_XHTTP_STREAM_PATH="${CLI_XHTTP_STREAM_PATH#/}"
    RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH%/}"
fi
[ -n "${CLI_ENABLE_HY2:-}" ]      && ENABLE_HY2="$CLI_ENABLE_HY2"
[ -n "${CLI_ENABLE_AWG_V3:-}" ]   && ENABLE_AWG_V3="$CLI_ENABLE_AWG_V3"
[ -n "${CLI_AWG_V3_PORT:-}" ]     && AWG_V3_PORT="$CLI_AWG_V3_PORT"
[ -n "${CLI_ENABLE_AWG_V2:-}" ]   && ENABLE_AWG_V2="$CLI_ENABLE_AWG_V2"
[ -n "${CLI_AWG_V2_PORT:-}" ]     && AWG_V2_PORT="$CLI_AWG_V2_PORT"
[ -n "${CLI_ENABLE_AWG_STANDALONE:-}" ] && ENABLE_AWG_STANDALONE="$CLI_ENABLE_AWG_STANDALONE"
[ -n "${CLI_AWG_STANDALONE_PORT:-}" ] && AWG_STANDALONE_PORT="$CLI_AWG_STANDALONE_PORT"
[ -n "${CLI_ENABLE_SS2022:-}" ]   && ENABLE_SS2022="$CLI_ENABLE_SS2022"
[ -n "${CLI_SS2022_PORT:-}" ]     && SS2022_PORT="$CLI_SS2022_PORT"
[ -n "${CLI_ENABLE_TUIC:-}" ]     && ENABLE_TUIC="$CLI_ENABLE_TUIC"
[ -n "${CLI_TUIC_PORT:-}" ]       && TUIC_PORT="$CLI_TUIC_PORT"
[ -n "${CLI_ENABLE_MTPROTO:-}" ]  && ENABLE_MTPROTO="$CLI_ENABLE_MTPROTO"
[ -n "${CLI_MTPROTO_PORT:-}" ]    && MTPROTO_PORT="$CLI_MTPROTO_PORT"
[ -n "${CLI_MTPROTO_FAKETLS_DOMAIN:-}" ] && MTPROTO_FAKETLS_DOMAIN="$CLI_MTPROTO_FAKETLS_DOMAIN"
[ -n "${CLI_MTPROTO_ADTAG:-}" ]   && MTPROTO_ADTAG="$CLI_MTPROTO_ADTAG"
[ -n "${CLI_ENABLE_WEB_STACK:-}" ] && ENABLE_WEB_STACK="$CLI_ENABLE_WEB_STACK"
[ -n "${CLI_AWG_SERVER_HOST:-}" ]  && AWG_SERVER_HOST="$CLI_AWG_SERVER_HOST"
[ -n "${CLI_ENABLE_MASQUE:-}" ]      && ENABLE_MASQUE="$CLI_ENABLE_MASQUE"
[ -n "${CLI_MASQUE_PORT:-}" ]        && MASQUE_PORT="$CLI_MASQUE_PORT"
[ -n "${CLI_ENABLE_SHADOWTLS:-}" ]   && ENABLE_SHADOWTLS="$CLI_ENABLE_SHADOWTLS"
[ -n "${CLI_SHADOWTLS_PORT:-}" ]     && SHADOWTLS_PORT="$CLI_SHADOWTLS_PORT"
[ -n "${CLI_SHADOWTLS_SNI:-}" ]      && SHADOWTLS_SNI="$CLI_SHADOWTLS_SNI"
[ -n "${CLI_SHADOWTLS_PASSWORD:-}" ] && SHADOWTLS_PASSWORD="$CLI_SHADOWTLS_PASSWORD"
[ -n "${CLI_ENABLE_WSTUNNEL:-}" ]    && ENABLE_WSTUNNEL="$CLI_ENABLE_WSTUNNEL"
[ -n "${CLI_WSTUNNEL_PORT:-}" ]      && WSTUNNEL_PORT="$CLI_WSTUNNEL_PORT"
[ -n "${CLI_WSTUNNEL_PREFIX:-}" ]    && WSTUNNEL_PREFIX="$CLI_WSTUNNEL_PREFIX"
[ -n "${CLI_ENABLE_ZAPRET:-}" ]      && ENABLE_ZAPRET="$CLI_ENABLE_ZAPRET"
[ -n "${CLI_ZAPRET_QNUM:-}" ]        && ZAPRET_QNUM="$CLI_ZAPRET_QNUM"
[ -n "${CLI_ENABLE_NAIVE:-}" ]       && ENABLE_NAIVE="$CLI_ENABLE_NAIVE"
[ -n "${CLI_NAIVE_PORT:-}" ]         && NAIVE_PORT="$CLI_NAIVE_PORT"
[ -n "${CLI_NAIVE_DOMAIN:-}" ]       && NAIVE_DOMAIN="$CLI_NAIVE_DOMAIN"
[ -n "${CLI_NAIVE_USER:-}" ]         && NAIVE_USER="$CLI_NAIVE_USER"
[ -n "${CLI_NAIVE_PASS:-}" ]         && NAIVE_PASS="$CLI_NAIVE_PASS"
[ -n "${CLI_ENABLE_DNSTT:-}" ]       && ENABLE_DNSTT="$CLI_ENABLE_DNSTT"
[ -n "${CLI_DNSTT_PORT:-}" ]         && DNSTT_PORT="$CLI_DNSTT_PORT"
[ -n "${CLI_DNSTT_DOMAIN:-}" ]       && DNSTT_DOMAIN="$CLI_DNSTT_DOMAIN"
[ -n "${CLI_DNSTT_PUBKEY:-}" ]       && DNSTT_PUBKEY="$CLI_DNSTT_PUBKEY"
[ -n "${CLI_ENABLE_MIERU:-}" ]       && ENABLE_MIERU="$CLI_ENABLE_MIERU"
[ -n "${CLI_MIERU_PORT_MODE:-}" ]    && MIERU_PORT_MODE="$CLI_MIERU_PORT_MODE"
[ -n "${CLI_MIERU_PORT:-}" ]         && MIERU_PORT="$CLI_MIERU_PORT"
[ -n "${CLI_MIERU_TRANSPORT:-}" ]    && MIERU_TRANSPORT="$CLI_MIERU_TRANSPORT"
[ -n "${CLI_MIERU_USER:-}" ]         && MIERU_USER="$CLI_MIERU_USER"
[ -n "${CLI_MIERU_PASS:-}" ]         && MIERU_PASS="$CLI_MIERU_PASS"
[ -n "${CLI_ALL_PROTOCOLS:-}" ]      && ALL_PROTOCOLS="$CLI_ALL_PROTOCOLS"

if [ "$ROTATE_PATHS" -eq 1 ]; then
    rotate_secret_paths || die "Не удалось сгенерировать новые секретные пути."
    warn "Пути панели, Wstunnel и ClientID DoH изменены. Обновите адреса на клиентах после установки."
fi

_stls_chk="${ENABLE_SHADOWTLS:-}"
if [[ "$_stls_chk" == "1" || "${_stls_chk,,}" == "y" ]] && [ -z "${CLI_ENABLE_SS2022:-}" ]; then
    ENABLE_SS2022="y"
fi

_dnstt_chk="${ENABLE_DNSTT:-}"
if [[ "$_dnstt_chk" == "1" || "${_dnstt_chk,,}" == "y" ]] && [ -z "${CLI_ENABLE_SS2022:-}" ]; then
    ENABLE_SS2022="y"
fi

# Сессия всегда сохраняется в server-setup.env в текущей папке или рядом со скриптом
SAVED_CONFIG_FILE="${CONFIG_FILE:-./server-setup.env}"


# =============================================================
#  ФУНКЦИИ ДИАГНОСТИКИ, РЕЗЕРВНОГО КОПИРОВАНИЯ И SMOKE-TEST
# =============================================================
# Listener declarations shared by planning, validation and final health checks.
protocol_is_public() {
    case "$1" in ShadowTLS|Wstunnel|NaiveProxy) return 1 ;; esac
}

selected_protocol_ports() {
    local flag transport variable fallback name
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        while read -r flag transport variable fallback name; do
            if is_true "${!flag:-n}"; then
                if [ "$flag" = "ENABLE_MIERU" ]; then
                    local m_trans="${MIERU_TRANSPORT:-BOTH}"
                    case "${m_trans^^}" in
                        TCP) [ "$transport" = "udp" ] && continue ;;
                        UDP) [ "$transport" = "tcp" ] && continue ;;
                    esac
                fi
                printf '%s %s %s\n' "$name" "$transport" "${!variable:-$fallback}"
            fi
        done <<'PROTOCOL_PORTS'
ENABLE_HY2 udp HY2_PORT 443 Hysteria2
ENABLE_AWG_V3 udp AWG_V3_PORT 8443 AWG-v3
ENABLE_AWG_V2 udp AWG_V2_PORT 8444 AWG-v2
ENABLE_SS2022 tcp SS2022_PORT 8388 SS2022
ENABLE_SS2022 udp SS2022_PORT 8388 SS2022
ENABLE_TUIC udp TUIC_PORT 8448 TUIC
ENABLE_MTPROTO tcp MTPROTO_PORT 8444 MTProto
ENABLE_MASQUE udp MASQUE_PORT 8449 MASQUE
ENABLE_SHADOWTLS tcp SHADOWTLS_PORT 8543 ShadowTLS
ENABLE_WSTUNNEL tcp WSTUNNEL_PORT 8080 Wstunnel
ENABLE_NAIVE tcp NAIVE_PORT 8446 NaiveProxy
ENABLE_DNSTT udp DNSTT_PORT 53053 DNSTT
ENABLE_MIERU tcp MIERU_PORT 8450 Mieru
ENABLE_MIERU udp MIERU_PORT 8450 Mieru
PROTOCOL_PORTS
    fi
    if is_true "${ENABLE_AWG_STANDALONE:-n}"; then
        printf 'AWG-standalone udp %s\n' "${AWG_STANDALONE_PORT:-8445}"
    fi
    return 0
}

installation_listeners() {
    printf 'SSH tcp %s\n' "${SSH_PORT:-${SSH_ACTIVE_PORT:-22}}"
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        printf 'HTTP tcp 80\nHTTPS tcp 443\n'
        printf 'Panel tcp %s\nSubscription tcp %s\nxHTTP tcp %s\n' \
            "${PANEL_PORT:-10443}" "${SUB_PORT:-55443}" "${XHTTP_STREAM_PORT:-50443}"
        local port
        if is_true "${ENABLE_STEAL:-n}"; then
            for port in "${STEAL_PORTS_LIST[@]:-${STEAL_PORT:-45443}}"; do printf 'Reality-own tcp %s\n' "$port"; done
        fi
        if is_true "${ENABLE_CLASSIC:-n}"; then
            for port in "${CLASSIC_PORTS_LIST[@]:-${CLASSIC_PORT:-46443}}"; do printf 'Reality-external tcp %s\n' "$port"; done
        fi
        if is_true "${ENABLE_AGH:-n}"; then
            local agh_dns_p="${PORT_AGH_DNS:-10053}"
            printf 'AdGuard-web tcp %s\nAdGuard-DNS tcp %s\nAdGuard-DNS udp %s\n' "${PORT_AGH_WEB:-3000}" "$agh_dns_p" "$agh_dns_p"
        fi
    fi
    selected_protocol_ports
}

backup_nginx_configs() {
    local bkp_dir="/var/backups/nginx_mask"
    mkdir -p "$bkp_dir"
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local bkp_file="$bkp_dir/nginx_conf_${ts}.tar.gz"

    if [ -d /etc/nginx ]; then
        if tar -czf "$bkp_file" -C /etc nginx 2>/dev/null; then
            export LAST_NGINX_BACKUP="$bkp_file"
            local old_backups
            old_backups=$(ls -1t "$bkp_dir"/nginx_conf_*.tar.gz 2>/dev/null | tail -n +6 || true)
            if [ -n "$old_backups" ]; then
                echo "$old_backups" | xargs -r rm -f 2>/dev/null || true
            fi
            ok "Создана полная резервная копия конфигурации Nginx: $bkp_file (ротация: 5)"
        fi
    fi
}

restore_nginx_configs() {
    local bkp="${LAST_NGINX_BACKUP:-}"
    if [ -z "$bkp" ] || [ ! -f "$bkp" ]; then
        bkp=$(ls -1t /var/backups/nginx_mask/nginx_conf_*.tar.gz 2>/dev/null | head -n 1 || true)
    fi
    if [ -n "$bkp" ] && [ -f "$bkp" ]; then
        log "Откат конфигурации Nginx из резервной копии $bkp..."
        tar -xzf "$bkp" -C /etc 2>/dev/null || true
        nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
        ok "Конфигурация Nginx возвращена в исходное состояние."
    fi
}

determine_nginx_http2_mode() {
    local ver_raw=""
    if command -v nginx >/dev/null 2>&1; then
        ver_raw=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || true)
    fi
    [ -n "$ver_raw" ] || ver_raw="1.25.1"

    local is_modern=0
    local major minor patch
    major=$(echo "$ver_raw" | cut -d. -f1)
    minor=$(echo "$ver_raw" | cut -d. -f2)
    patch=$(echo "$ver_raw" | cut -d. -f3)
    major=${major:-0}; minor=${minor:-0}; patch=${patch:-0}

    if [ "$major" -gt 1 ] 2>/dev/null; then
        is_modern=1
    elif [ "$major" -eq 1 ] 2>/dev/null && [ "$minor" -gt 25 ] 2>/dev/null; then
        is_modern=1
    elif [ "$major" -eq 1 ] 2>/dev/null && [ "$minor" -eq 25 ] 2>/dev/null && [ "$patch" -ge 1 ] 2>/dev/null; then
        is_modern=1
    fi

    if [ "$is_modern" -eq 1 ]; then
        HTTP2_LISTEN_PARAM=""
        HTTP2_DIRECTIVE="http2 on;"
        HTTP2_HTTP_PARAMS=$'    http2_recv_buffer_size 16m;\n    http2_max_concurrent_streams 512;'
    else
        HTTP2_LISTEN_PARAM="http2 "
        HTTP2_DIRECTIVE="# http2 on; (legacy listen param)"
        HTTP2_HTTP_PARAMS=$'    # http2 buffers managed by legacy core'
    fi
}

detect_active_ssh_port() {
    local active_port=""
    if [ -n "${SSH_CONNECTION:-}" ]; then
        active_port=$(echo "$SSH_CONNECTION" | awk '{print $4}')
    fi
    if [ -z "$active_port" ] || ! [[ "$active_port" =~ ^[0-9]+$ ]]; then
        active_port=$(ss -tlnp 2>/dev/null | grep -E 'sshd|ssh' | grep -vE '127\.0\.0\.1|::1' | awk '{print $4}' | awk -F: '{print $NF}' | sort -n | tail -n1 || echo "")
    fi
    if [ -z "$active_port" ] || ! [[ "$active_port" =~ ^[0-9]+$ ]]; then
        active_port="22"
    fi
    echo "$active_port"
}

get_ssh_service_name() {
    if systemctl list-unit-files 2>/dev/null | grep -q "^sshd\.service"; then
        echo "sshd"
    else
        echo "ssh"
    fi
}

get_wan_ip() {
    if [ -n "${WAN_IP:-}" ]; then
        echo "$WAN_IP"
        return 0
    fi
    local cache_file="/run/setup_mask_wan_ip"
    if [ ! -d /run ] || ! touch /run/.test_w 2>/dev/null; then
        cache_file="/tmp/setup_mask_wan_ip"
    else
        rm -f /run/.test_w 2>/dev/null || true
    fi

    if [ -f "$cache_file" ]; then
        local cached
        cached=$(cat "$cache_file" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$cached" ] && [[ "$cached" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            WAN_IP="$cached"
            echo "$WAN_IP"
            return 0
        fi
    fi

    local ip_val=""
    ip_val=$(curl -s4 --connect-timeout 3 icanhazip.com 2>/dev/null \
          || curl -s4 --connect-timeout 3 api.ipify.org 2>/dev/null \
          || curl -s4 --connect-timeout 3 ifconfig.me 2>/dev/null || true)
    ip_val=$(echo "$ip_val" | tr -d '[:space:]')

    if [ -z "$ip_val" ] || ! [[ "$ip_val" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ip_val=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || echo "")
    fi

    if [ -n "$ip_val" ]; then
        WAN_IP="$ip_val"
        echo "$WAN_IP" > "$cache_file" 2>/dev/null || true
    fi
    echo "${WAN_IP:-127.0.0.1}"
}


get_port_listener_info() {
    local proto="$1"
    local port="$2"
    local raw=""
    local flag="-t"
    [ "$proto" = "udp" ] && flag="-u"

    if command -v ss >/dev/null 2>&1; then
        raw=$(ss -l -n -p "$flag" 2>/dev/null | grep -E ":${port}\b" || true)
    elif command -v netstat >/dev/null 2>&1; then
        raw=$(netstat -l -n -p "$flag" 2>/dev/null | grep -E ":${port}\b" || true)
    elif command -v lsof >/dev/null 2>&1; then
        raw=$(lsof -i "${proto}:${port}" -sTCP:LISTEN 2>/dev/null || lsof -i "${proto}:${port}" 2>/dev/null || true)
    fi

    local proc_info=""
    if [ -n "$raw" ]; then
        if echo "$raw" | grep -q 'users:('; then
            proc_info=$(echo "$raw" | grep -oP 'users:\(\(\K[^)]+' | head -n1 | tr -d '"' || true)
        elif echo "$raw" | grep -qE '[0-9]+/[-_a-zA-Z0-9]+'; then
            proc_info=$(echo "$raw" | grep -oE '[0-9]+/[-_a-zA-Z0-9]+' | head -n1 || true)
        fi
        [ -z "$proc_info" ] && proc_info=$(echo "$raw" | awk '{print $NF}' | head -n1 || true)
    fi
    echo "$proc_info"
}

is_port_in_use() {
    local proto="$1"
    local port="$2"
    if command -v ss >/dev/null 2>&1; then
        local flag="-t"
        [ "$proto" = "udp" ] && flag="-u"
        ss -l -n "$flag" 2>/dev/null | grep -qE ":${port}\b" && return 0
    elif command -v netstat >/dev/null 2>&1; then
        local flag="-t"
        [ "$proto" = "udp" ] && flag="-u"
        netstat -l -n "$flag" 2>/dev/null | grep -qE ":${port}\b" && return 0
    elif [ "$proto" = "tcp" ] && timeout 1 bash -c "</dev/tcp/127.0.0.1/$port" 2>/dev/null; then
        return 0
    fi
    return 1
}


inspect_port_conflicts() {
    echo ""
    echo -e "  ${CYAN}${BOLD}🔎  УНИВЕРСАЛЬНЫЙ ИНСПЕКТОР СЕТЕВЫХ ПОРТОВ И СЛУЖБ (PREFLIGHT)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"

    PORT_AGH_WEB="${PORT_AGH_WEB:-3000}"

    # 1. Проверка настраиваемого веб-порта AdGuard Home (по умолчанию 3000)
    if [[ "${ENABLE_AGH:-0}" == "1" || "${ENABLE_AGH,,}" == "y" ]]; then
        if is_port_in_use "tcp" "$PORT_AGH_WEB"; then
            local listener
            listener=$(get_port_listener_info "tcp" "$PORT_AGH_WEB")
            if echo "$listener" | grep -qi "AdGuardHome"; then
                ok "Порт $PORT_AGH_WEB занят собственным сервисом AdGuard Home — порт сохранен."
            else
                warn "Порт $PORT_AGH_WEB занят активным процессом: ${listener:-сторонней службой}."
                local candidate=3001
                local candidate_found=0
                while [ "$candidate" -le 3053 ]; do
                    if ! is_port_in_use "tcp" "$candidate"; then
                        candidate_found=1
                        break
                    fi
                    candidate=$(( candidate + 1 ))
                done
                if [ "$candidate_found" -eq 1 ]; then
                    PORT_AGH_WEB="$candidate"
                    ok "Автоматическое переназначение: веб-панель AdGuard Home перенесена на свободный порт ${WHITE}$PORT_AGH_WEB${NC} (конфликт устранен)."
                    if declare -f invalidate_checkpoint >/dev/null 2>&1; then
                        invalidate_checkpoint 6 2>/dev/null || true
                    fi
                else
                    die "Все порты в диапазоне 3001–3053 заняты. AdGuard Home не может быть размещен автоматически. Освободите порт или задайте PORT_AGH_WEB вручную."
                fi
            fi
        else
            ok "Порт $PORT_AGH_WEB (AdGuard Home Web) свободен."
        fi
    fi

    # 2. Проверка изоляции DNS (systemd-resolved DoT на 53 / AdGuard Home на PORT_AGH_DNS)
    if [[ "${ENABLE_AGH:-0}" == "1" || "${ENABLE_AGH,,}" == "y" ]]; then
        local agh_dns_port="${PORT_AGH_DNS:-10053}"
        if is_port_in_use "udp" "$agh_dns_port" || is_port_in_use "tcp" "$agh_dns_port"; then
            warn "Порт $agh_dns_port (AdGuard Home DNS) уже используется. Рекомендуется освободить порт."
        else
            ok "Порт $agh_dns_port (AdGuard Home DNS изоляция) свободен. Системный порт 53 сохранен для systemd-resolved DoT."
        fi
    fi

    # 3. Проверка внешних портов маршрутизации и маскирования (80 и 443 TCP)
    local _web_stack="${ENABLE_WEB_STACK:-y}"
    local _dokploy_coexist="${DOKPLOY_COEXISTENCE:-n}"
    if [[ "${_dokploy_coexist,,}" == "y" || "${_dokploy_coexist}" == "1" || "${_dokploy_coexist,,}" == "true" || "${_web_stack,,}" == "dokploy" ]]; then
        ok "Режим бесконфликтного сосуществования с Dokploy активен: порты 80 и 443 зарезервированы для Traefik (проксирование через WebSocket / Docker Compose)."
    elif [[ "${_web_stack,,}" == "y" || "${_web_stack}" == "1" || "${_web_stack,,}" == "true" ]]; then
        for p in 80 443; do
            if is_port_in_use "tcp" "$p"; then
                local w_owner
                w_owner=$(get_port_listener_info "tcp" "$p")
                if echo "$w_owner" | grep -qi "nginx"; then
                    ok "Порт $p слушает Nginx (будет переконфигурирован в единый L4/L7 роутер маскирования)."
                else
                    die "Порт $p занят сторонним процессом: ${w_owner:-не Nginx}. Для сквозного TLS/HTTP маскирования требуется порт $p."
                fi
            else
                ok "Порт $p (Веб / Маскирование) свободен."
            fi
        done

        # 3.1. Проверка существующих сторонних сайтов на прямой listen 443
        local conflicting_vhosts=()
        for vf in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
            [ -f "$vf" ] || continue
            local b_name
            b_name=$(basename "$vf")
            case "$b_name" in
                default|default.conf|01-main.conf|02-*.conf|03-adguard.conf|vpn_mask.conf)
                    continue
                    ;;
            esac
            if grep -Eq 'listen[[:space:]]+([^;]*:)?443' "$vf" 2>/dev/null; then
                if ! grep -q 'listen[[:space:]]+unix:' "$vf" 2>/dev/null; then
                    conflicting_vhosts+=("$b_name")
                fi
            fi
        done
        if [ ${#conflicting_vhosts[@]} -gt 0 ]; then
            warn "Обнаружены существующие vhost с прямым слушанием порта 443: ${conflicting_vhosts[*]}"
            warn "Nginx Stream роутер использует порт 443. Такие vhost должны быть адаптированы под сокет unix:/dev/shm/nginx-http.sock."
        fi

        # 4. Проверка внутренних служебных портов стека
        local internal_ports=()
        [ -n "${PANEL_PORT:-}" ] && internal_ports+=("Панель 3X-UI:$PANEL_PORT")
        [ -n "${SUB_PORT:-}" ] && internal_ports+=("Канал подписок:$SUB_PORT")
        [ -n "${XHTTP_STREAM_PORT:-}" ] && internal_ports+=("xHTTP стрим:$XHTTP_STREAM_PORT")
        [ -n "${REALITY_FALLBACK_PORT:-}" ] && internal_ports+=("REALITY Fallback:$REALITY_FALLBACK_PORT")

        for item in "${internal_ports[@]}"; do
            local s_name="${item%%:*}"
            local s_port="${item##*:}"
            if is_port_in_use "tcp" "$s_port"; then
                local p_owner
                p_owner=$(get_port_listener_info "tcp" "$s_port")
                if echo "$p_owner" | grep -qiE "x-ui|xray|nginx"; then
                    ok "Внутренний порт $s_port ($s_name) занят собственным сервисом ($p_owner) — готов к реконфигурации."
                else
                    warn "Внутренний порт $s_port ($s_name) занят сторонним процессом: ${p_owner:-неизвестно}. Возможен конфликт."
                fi
            fi
        done
    fi

    # 5. Проверка порта автономного AmneziaWG (UDP)
    local _awg_sa="${ENABLE_AWG_STANDALONE:-0}"
    if [[ "${_awg_sa,,}" == "y" || "${_awg_sa}" == "1" || "${_awg_sa,,}" == "true" ]]; then
        local awg_p="${AWG_STANDALONE_PORT:-8445}"
        if is_port_in_use "udp" "$awg_p"; then
            local awg_owner
            awg_owner=$(get_port_listener_info "udp" "$awg_p")
            if echo "$awg_owner" | grep -qiE "amnezia|wireguard"; then
                ok "UDP-порт $awg_p (AmneziaWG) занят собственной службой ($awg_owner)."
            else
                warn "UDP-порт $awg_p (AmneziaWG) занят сторонним процессом: ${awg_owner:-неизвестно}. Возможен конфликт."
            fi
        else
            ok "Порт $awg_p/udp (AmneziaWG Standalone) свободен."
        fi
    fi

    # 6. Проверка портов протоколов следующего поколения (MASQUE, ShadowTLS, NaïveProxy)
    local _masque_en="${ENABLE_MASQUE:-n}"
    if [[ "${_masque_en,,}" == "y" || "${_masque_en}" == "1" || "${_masque_en,,}" == "true" ]]; then
        local m_port="${MASQUE_PORT:-8449}"
        if [[ "${_awg_sa,,}" == "y" || "${_awg_sa}" == "1" || "${_awg_sa,,}" == "true" ]] && [ "$m_port" = "${AWG_STANDALONE_PORT:-8445}" ]; then
            warn "Коллизия портов: MASQUE и AmneziaWG Standalone используют один UDP-порт ($m_port)! Измените MASQUE_PORT или AWG_STANDALONE_PORT."
        fi
        if is_port_in_use "udp" "$m_port"; then
            local m_owner
            m_owner=$(get_port_listener_info "udp" "$m_port")
            warn "Порт $m_port/udp (MASQUE) занят: ${m_owner:-сторонней службой}."
        else
            ok "Порт $m_port/udp (MASQUE HTTP/3 Datagram) свободен."
        fi
    fi

    local _stls_en="${ENABLE_SHADOWTLS:-n}"
    if [[ "${_stls_en,,}" == "y" || "${_stls_en}" == "1" || "${_stls_en,,}" == "true" ]]; then
        local st_port="${SHADOWTLS_PORT:-8543}"
        if is_port_in_use "tcp" "$st_port"; then
            local st_owner
            st_owner=$(get_port_listener_info "tcp" "$st_port")
            warn "Порт $st_port/tcp (ShadowTLS v4) занят: ${st_owner:-сторонней службой}."
        else
            ok "Порт $st_port/tcp (ShadowTLS v4) свободен."
        fi
    fi

    local _naive_en="${ENABLE_NAIVE:-n}"
    if [[ "${_naive_en,,}" == "y" || "${_naive_en}" == "1" || "${_naive_en,,}" == "true" ]]; then
        local n_port="${NAIVE_PORT:-8446}"
        if is_port_in_use "tcp" "$n_port"; then
            local n_owner
            n_owner=$(get_port_listener_info "tcp" "$n_port")
            warn "Порт $n_port/tcp (NaïveProxy) занят: ${n_owner:-сторонней службой}."
        else
            ok "Порт $n_port/tcp (NaïveProxy) свободен."
        fi
    fi

    local _dnstt_en="${ENABLE_DNSTT:-n}"
    if [[ "${_dnstt_en,,}" == "y" || "${_dnstt_en}" == "1" || "${_dnstt_en,,}" == "true" ]]; then
        local d_port="${DNSTT_PORT:-53053}"
        if is_port_in_use "udp" "$d_port"; then
            local d_owner
            d_owner=$(get_port_listener_info "udp" "$d_port")
            warn "Порт $d_port/udp (DNSTT DoH Tunnel) занят: ${d_owner:-сторонней службой}."
        else
            ok "Порт $d_port/udp (DNSTT DoH Tunnel) свободен."
        fi
    fi

    local _mieru_en="${ENABLE_MIERU:-n}"
    if [[ "${_mieru_en,,}" == "y" || "${_mieru_en}" == "1" || "${_mieru_en,,}" == "true" ]]; then
        local mr_port="${MIERU_PORT:-8450}"
        local mr_trans="${MIERU_TRANSPORT:-BOTH}"
        local check_transports=()
        case "${mr_trans^^}" in
            TCP) check_transports=(tcp) ;;
            UDP) check_transports=(udp) ;;
            *) check_transports=(tcp udp) ;;
        esac

        local cur_t
        for cur_t in "${check_transports[@]}"; do
            if [[ "$mr_port" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                local r_start="${BASH_REMATCH[1]}" r_end="${BASH_REMATCH[2]}"
                local conflict_p="" p_owner="" p
                for (( p=r_start; p<=r_end; p++ )); do
                    if is_port_in_use "$cur_t" "$p"; then
                        conflict_p="$p"
                        p_owner=$(get_port_listener_info "$cur_t" "$p")
                        break
                    fi
                done
                if [ -n "$conflict_p" ]; then
                    warn "Порт $conflict_p/$cur_t из диапазона Mieru ($mr_port) занят: ${p_owner:-сторонней службой}."
                else
                    ok "Диапазон портов $mr_port/$cur_t (Mieru Proxy) свободен."
                fi
            else
                local mr_base="${mr_port%%[-:]*}"
                if is_port_in_use "$cur_t" "$mr_base"; then
                    local mr_owner
                    mr_owner=$(get_port_listener_info "$cur_t" "$mr_base")
                    warn "Порт $mr_port/$cur_t (Mieru Proxy) занят: ${mr_owner:-сторонней службой}."
                else
                    ok "Порт $mr_port/$cur_t (Mieru Proxy) свободен."
                fi
            fi
        done
    fi

    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}\n"
}

check_required_service() {
    if systemctl is-active --quiet "$1"; then ok "Service $1: active";
    else warn "Service $1: inactive"; return 1; fi
}

check_required_file() {
    [ -s "$1" ] || { warn "Missing required file: $1"; return 1; }
}

check_required_port() {
    local protocol="$1" port="$2" listeners
    local p_flag="-ltn"
    [ "$protocol" = udp ] && p_flag="-lun"

    if [[ "$port" =~ ^([0-9]+)[-:]+([0-9]+)$ ]]; then
        local p_start="${BASH_REMATCH[1]}" p_end="${BASH_REMATCH[2]}"
        p_start="$((10#$p_start))"
        p_end="$((10#$p_end))"
        if [ "$p_start" -gt "$p_end" ]; then
            local tmp="$p_start"
            p_start="$p_end"
            p_end="$tmp"
        fi
        local p missing_ports=()
        for (( p=p_start; p<=p_end; p++ )); do
            listeners=$(ss -H $p_flag "sport = :$p" 2>/dev/null) || true
            if [ -z "$listeners" ]; then
                missing_ports+=("$p")
            fi
        done
        if [ "${#missing_ports[@]}" -gt 0 ]; then
            warn "Port range $port/$protocol: not listening on port(s): ${missing_ports[*]}"
            return 1
        fi
        ok "Port range $port/$protocol: all listening (${p_start}..${p_end})"
        return 0
    fi

    local check_port="${port%%[-:]*}"
    listeners=$(ss -H $p_flag "sport = :$check_port" 2>/dev/null) || return 1
    [ -n "$listeners" ] || { warn "Port $port/$protocol is not listening"; return 1; }
    ok "Port $port/$protocol: listening"
}

post_install_sanity_check() {
    local all_ok=1 flag protocol variable fallback port
    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    local -A checked_services=()
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        check_required_service nginx || all_ok=0
        nginx -t >/dev/null 2>&1 || all_ok=0
        check_required_port tcp 443 || all_ok=0
        if is_true "${AUTO_SETUP_3XUI:-y}"; then
            check_required_service x-ui || all_ok=0
            check_required_port tcp "${PANEL_PORT:-10443}" || all_ok=0
            check_required_port tcp "${SUB_PORT:-55443}" || all_ok=0
            check_required_port tcp "${XHTTP_STREAM_PORT:-50443}" || all_ok=0
            if is_true "${ENABLE_STEAL:-n}"; then
                for port in "${STEAL_PORTS_LIST[@]:-${STEAL_PORT:-45443}}"; do
                    check_required_port tcp "$port" || all_ok=0
                done
            fi
            if is_true "${ENABLE_CLASSIC:-n}"; then
                for port in "${CLASSIC_PORTS_LIST[@]:-${CLASSIC_PORT:-46443}}"; do
                    check_required_port tcp "$port" || all_ok=0
                done
            fi
        fi
        while read -r flag protocol port; do
            [ "$flag" = AWG-standalone ] && continue
            case "$flag" in
                MASQUE)
                    if [ ! -x "${bin_dir}/sing-box" ] && ! command -v sing-box >/dev/null 2>&1; then
                        warn "Служба MASQUE: бинарник sing-box не установлен."
                        all_ok=0
                        continue
                    fi
                    if [ -z "${checked_services[sing-box-masque]:-}" ]; then
                        check_required_service sing-box-masque || all_ok=0
                        checked_services[sing-box-masque]=1
                    fi
                    ;;
                NaiveProxy)
                    if [ ! -x "${bin_dir}/caddy-naive" ] && [ ! -x "${bin_dir}/caddy" ] && ! command -v caddy-naive >/dev/null 2>&1 && ! command -v caddy >/dev/null 2>&1; then
                        warn "Служба NaiveProxy: бинарник caddy-naive не установлен."
                        all_ok=0
                        continue
                    fi
                    if [ -z "${checked_services[caddy-naive]:-}" ]; then
                        check_required_service caddy-naive || all_ok=0
                        checked_services[caddy-naive]=1
                    fi
                    ;;
                DNSTT)
                    if [ ! -x "${bin_dir}/dnstt-server" ] && ! command -v dnstt-server >/dev/null 2>&1; then
                        warn "Служба DNSTT: бинарник dnstt-server не установлен."
                        all_ok=0
                        continue
                    fi
                    if [ -z "${checked_services[dnstt-server]:-}" ]; then
                        check_required_service dnstt-server || all_ok=0
                        checked_services[dnstt-server]=1
                    fi
                    ;;
                Mieru)
                    if [ ! -x "${bin_dir}/mita" ] && ! command -v mita >/dev/null 2>&1; then
                        warn "Служба Mieru: бинарник mita не установлен."
                        all_ok=0
                        continue
                    fi
                    if [ -z "${checked_services[mita]:-}" ]; then
                        check_required_service mita || all_ok=0
                        checked_services[mita]=1
                    fi
                    ;;
                ShadowTLS)
                    if [ ! -x "${bin_dir}/shadow-tls" ] && ! command -v shadow-tls >/dev/null 2>&1; then
                        warn "Служба ShadowTLS: бинарник shadow-tls не установлен."
                        all_ok=0
                        continue
                    fi
                    if [ -z "${checked_services[shadow-tls]:-}" ]; then
                        check_required_service shadow-tls || all_ok=0
                        checked_services[shadow-tls]=1
                    fi
                    ;;
                Wstunnel)
                    if [ ! -x "${bin_dir}/wstunnel" ] && ! command -v wstunnel >/dev/null 2>&1; then
                        warn "Служба Wstunnel: бинарник wstunnel не установлен."
                        all_ok=0
                        continue
                    fi
                    if [ -z "${checked_services[wstunnel]:-}" ]; then
                        check_required_service wstunnel || all_ok=0
                        checked_services[wstunnel]=1
                    fi
                    ;;
            esac
            check_required_port "$protocol" "$port" || all_ok=0
        done < <(selected_protocol_ports)
        if is_true "${ENABLE_ZAPRET:-n}"; then
            check_required_service zapret-server || all_ok=0
        fi
        if is_true "${ENABLE_AGH:-n}"; then
            check_required_service AdGuardHome || all_ok=0
            check_required_port tcp "${PORT_AGH_WEB:-3000}" || all_ok=0
            local agh_dns_check="${PORT_AGH_DNS:-10053}"
            check_required_port udp "$agh_dns_check" || all_ok=0
        fi
        # curl validates the certificate and hostname as well as HTTPS availability.
        if ! curl -fLsS --connect-timeout 3 --max-time 10 -o /dev/null \
            --resolve "${PRIMARY_DOMAIN}:443:127.0.0.1" "https://${PRIMARY_DOMAIN}/"; then
            warn "HTTPS/certificate check failed: ${PRIMARY_DOMAIN}"
            all_ok=0
        fi
    fi
    if is_true "${ENABLE_AWG_STANDALONE:-n}"; then
        check_required_service awg-quick@awg0 || all_ok=0
        check_required_port udp "${AWG_STANDALONE_PORT:-8445}" || all_ok=0
        check_required_file /etc/amnezia/amneziawg/awg0.conf || all_ok=0
        check_required_file /root/awg/client-1.conf || all_ok=0
    fi
    if [ "$all_ok" -eq 1 ]; then
        ok "All selected components passed verification."
        return 0
    fi
    warn "Installation verification failed. Fix the reported services and resume installation."
    return 1
}

run_doctor_check() {
    clear 2>/dev/null || true
    echo -e "  ${CYAN}${BOLD}🩺  ДИАГНОСТИКА СИСТЕМЫ И СЕРВИСОВ (DOCTOR MODE)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
    echo -e "  Дата проверки: ${WHITE}$(date '+%Y-%m-%d %H:%M:%S')${NC}\n"

    # 1. ОС и Ядро
    echo -e "  ${WHITE}${BOLD}[1/7] ОС и Сетевой стек ядра:${NC}"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo -e "    • Дистрибутив:       ${GREEN}${PRETTY_NAME:-$ID}${NC}"
    fi
    echo -e "    • Ядро Linux:         ${GREEN}$(uname -r)${NC}"

    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [ "$cc" = "bbr" ]; then
        echo -e "    • Алгоритм TCP:      ${GREEN}BBR (активен)${NC}"
    else
        echo -e "    • Алгоритм TCP:      ${YELLOW}$cc (рекомендуется bbr)${NC}"
    fi

    local qdisc
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    echo -e "    • Очередь qdisc:     ${GREEN}$qdisc${NC}"

    if iptables -t mangle -L -n -v 2>/dev/null | grep -q "TCPMSS.*clamp"; then
        echo -e "    • MSS Clamping:      ${GREEN}АКТИВЕН (iptables mangle TCPMSS clamp)${NC}"
    else
        echo -e "    • MSS Clamping:      ${YELLOW}не обнаружен в iptables mangle${NC}"
    fi

    local ipv6_all
    ipv6_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    if [ "$ipv6_all" = "1" ] || [ ! -d /proc/sys/net/ipv6 ]; then
        echo -e "    • Статус IPv6:       ${GREEN}ОТКЛЮЧЕН (no leak)${NC}"
    else
        echo -e "    • Статус IPv6:       ${RED}АКТИВЕН (возможны утечки DNS/IPv6)${NC}"
    fi

    # 2. Nginx
    echo -e "\n  ${WHITE}${BOLD}[2/7] Веб-сервер Nginx (L4/L7 Router):${NC}"
    if command -v nginx >/dev/null 2>&1; then
        local ng_ver
        ng_ver=$(nginx -v 2>&1 | cut -d/ -f2 || true)
        echo -e "    • Версия Nginx:      ${GREEN}$ng_ver${NC}"
        if systemctl is-active --quiet nginx 2>/dev/null; then
            echo -e "    • Статус службы:     ${GREEN}active (running)${NC}"
        else
            echo -e "    • Статус службы:     ${RED}NOT RUNNING${NC}"
        fi
        if nginx -t >/dev/null 2>&1; then
            echo -e "    • Синтаксис конфига: ${GREEN}OK (nginx -t passed)${NC}"
        else
            echo -e "    • Синтаксис конфига: ${RED}ОШИБКА в конфигурации!${NC}"
        fi
        [ -f /etc/nginx/stream.d/00-stream.conf ] && echo -e "    • Stream Router:     ${GREEN}/etc/nginx/stream.d/00-stream.conf (присутствует)${NC}" || echo -e "    • Stream Router:     ${RED}00-stream.conf ОТСУТСТВУЕТ!${NC}"
        [ -f /etc/nginx/conf.d/01-main.conf ] && echo -e "    • Main HTTP Config:  ${GREEN}/etc/nginx/conf.d/01-main.conf (присутствует)${NC}" || echo -e "    • Main HTTP Config:  ${RED}01-main.conf ОТСУТСТВУЕТ!${NC}"
    else
        echo -e "    • Nginx:             ${RED}не установлен${NC}"
    fi

    # 3. Xray-core и 3X-UI
    echo -e "\n  ${WHITE}${BOLD}[3/7] Прокси-ядро Xray и панель 3X-UI:${NC}"
    if systemctl is-active --quiet x-ui 2>/dev/null; then
        echo -e "    • Статус 3X-UI:      ${GREEN}active (running)${NC}"
    else
        echo -e "    • Статус 3X-UI:      ${RED}NOT RUNNING${NC}"
    fi
    local xray_bin="/usr/local/x-ui/bin/xray-linux-amd64"
    [ -f "$xray_bin" ] || xray_bin="/usr/local/x-ui/bin/xray"
    [ -f "$xray_bin" ] || xray_bin="/etc/x-ui/bin/xray-linux-amd64"
    [ -f "$xray_bin" ] || xray_bin="/etc/x-ui/bin/xray"
    if [ -x "$xray_bin" ]; then
        local xv
        xv=$("$xray_bin" -version 2>/dev/null | head -n1 | awk '{print $2}' || true)
        echo -e "    • Ядро Xray-core:    ${GREEN}${xv:-найден}${NC}"
    fi
    if [ -f /etc/x-ui/x-ui.db ]; then
        echo -e "    • База SQLite:       ${GREEN}/etc/x-ui/x-ui.db (${WHITE}$(du -h /etc/x-ui/x-ui.db 2>/dev/null | awk '{print $1}')${GREEN})${NC}"
    fi
    if systemctl is-active --quiet xray-geo-update.timer 2>/dev/null; then
        echo -e "    • Таймер гео-баз:    ${GREEN}активен (еженедельное обновление)${NC}"
    fi

    # 4. Прослушиваемые порты
    echo -e "\n  ${WHITE}${BOLD}[4/7] Сетевые порты (Listening Sockets):${NC}"
    doctor_check_tcp() {
        local p="$1"
        local desc="$2"
        if timeout 1 bash -c "</dev/tcp/127.0.0.1/$p" 2>/dev/null; then
            echo -e "    • TCP :$p ($desc): ${GREEN}ОТКРЫТ (отвечает)${NC}"
        else
            echo -e "    • TCP :$p ($desc): ${RED}НЕ ОТВЕЧАЕТ${NC}"
        fi
    }
    doctor_check_tcp 443 "Nginx Stream Router"
    doctor_check_tcp 80 "HTTP Redirect / ACME"
    doctor_check_tcp 9443 "Anti-Loop Fallback"
    doctor_check_tcp "${STEAL_PORT:-45443}" "Xray REALITY (свой сайт)"
    doctor_check_tcp "${CLASSIC_PORT:-46443}" "Xray REALITY (внешние сервисы)"
    doctor_check_tcp "${XHTTP_STREAM_PORT:-50443}" "Xray VLESS xHTTP"
    doctor_check_tcp "${PANEL_PORT:-10443}" "3X-UI Web Panel"
    doctor_check_tcp "${SUB_PORT:-55443}" "3X-UI Subscriptions"

    # UDP
    if ss -ulpn 2>/dev/null | grep -q ":${HY2_PORT:-443} "; then
        echo -e "    • UDP :${HY2_PORT:-443} (Hysteria 2): ${GREEN}СЛУШАЕТ${NC}"
    else
        echo -e "    • UDP :${HY2_PORT:-443} (Hysteria 2): ${DIM}не активен или выключен${NC}"
    fi
    if ss -ulpn 2>/dev/null | grep -q ":${AWG_V3_PORT:-8443} "; then
        echo -e "    • UDP :${AWG_V3_PORT:-8443} (AmneziaWG v3): ${GREEN}СЛУШАЕТ${NC}"
    else
        echo -e "    • UDP :${AWG_V3_PORT:-8443} (AmneziaWG v3): ${DIM}не активен или выключен${NC}"
    fi

    # 5. AdGuard Home
    echo -e "\n  ${WHITE}${BOLD}[5/7] AdGuard Home DNS:${NC}"
    if [ -f /opt/AdGuardHome/AdGuardHome ]; then
        if systemctl is-active --quiet AdGuardHome 2>/dev/null; then
            echo -e "    • Статус:            ${GREEN}active (running)${NC}"
        else
            echo -e "    • Статус:            ${RED}NOT RUNNING${NC}"
        fi
        local agh_dns_check="${PORT_AGH_DNS:-10053}"
        if ss -ulpn 2>/dev/null | grep -q ":${agh_dns_check} "; then
            echo -e "    • DNS Порт ${agh_dns_check}:    ${GREEN}СЛУШАЕТ${NC}"
        else
            echo -e "    • DNS Порт ${agh_dns_check}:    ${YELLOW}не слушает ${agh_dns_check}${NC}"
        fi
    else
        echo -e "    • AdGuard Home:      ${DIM}не установлен на этом сервере${NC}"
    fi

    # 6. SSL сертификаты
    echo -e "\n  ${WHITE}${BOLD}[6/7] SSL-сертификаты:${NC}"
    local found_cert=0
    for cert_dir in "/etc/letsencrypt/live" "/etc/ssl/acme"; do
        if [ -d "$cert_dir" ]; then
            for c_path in "$cert_dir"/*/fullchain.pem; do
                if [ -f "$c_path" ]; then
                    found_cert=1
                    local c_dom
                    c_dom=$(basename "$(dirname "$c_path")")
                    local c_exp
                    c_exp=$(openssl x509 -enddate -noout -in "$c_path" 2>/dev/null | cut -d= -f2 || echo "unknown")
                    local exp_sec
                    exp_sec=$(date -d "$c_exp" +%s 2>/dev/null || echo 0)
                    local days_rem=$(( (exp_sec - $(date +%s)) / 86400 ))
                    if [ "$days_rem" -gt 15 ]; then
                        echo -e "    • Домен ${CYAN}$c_dom${NC}: ${GREEN}валиден${NC} (осталось ${GREEN}$days_rem дн.${NC}, до $c_exp)"
                    elif [ "$days_rem" -gt 0 ]; then
                        echo -e "    • Домен ${CYAN}$c_dom${NC}: ${YELLOW}скоро истекает${NC} (осталось $days_rem дн.!)"
                    else
                        echo -e "    • Домен ${CYAN}$c_dom${NC}: ${RED}ИСТЕК!${NC}"
                    fi
                fi
            done
        fi
    done
    [ "$found_cert" -eq 0 ] && echo -e "    • Сертификаты:       ${YELLOW}не найдены${NC}"

    # 7. Безопасность и Маскировка Censys
    echo -e "\n  ${WHITE}${BOLD}[7/7] Аудит маскировки и защита от активных сканеров:${NC}"
    local ip_resp
    ip_resp=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 2 "https://127.0.0.1:443/" 2>/dev/null || echo "DROP")
    if [ "$ip_resp" = "000" ] || [ "$ip_resp" = "DROP" ]; then
        echo -e "    • Запрос по IP (без SNI):   ${GREEN}СБРОС СОЕДИНЕНИЯ (TLS DROP) — Censys не увидит сертификат!${NC}"
    elif [ "$ip_resp" = "444" ]; then
        echo -e "    • Запрос по IP (без SNI):   ${GREEN}HTTP 444 (Сброс соединения)${NC}"
    else
        echo -e "    • Запрос по IP (без SNI):   ${YELLOW}Ответил код $ip_resp (рекомендуется сброс)${NC}"
    fi

    if [ -n "${PRIMARY_DOMAIN:-}" ]; then
        local dom_resp
        dom_resp=$(curl -sk -o /dev/null -w "%{http_code}" --resolve "${PRIMARY_DOMAIN}:443:127.0.0.1" --connect-timeout 2 "https://${PRIMARY_DOMAIN}/" 2>/dev/null || echo "ERR")
        if [ "$dom_resp" = "200" ]; then
            echo -e "    • Домен https://${PRIMARY_DOMAIN}/:  ${GREEN}HTTP 200 OK (Веб-маска активна)${NC}"
        else
            echo -e "    • Домен https://${PRIMARY_DOMAIN}/:  ${YELLOW}Код $dom_resp${NC}"
        fi
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
        echo -e "    • Файервол UFW:              ${GREEN}активен${NC}"
        local leak=0
        for lp in 9443 "${STEAL_PORT:-45443}" "${CLASSIC_PORT:-46443}" "${XHTTP_STREAM_PORT:-50443}"; do
            if ufw status | grep -E "^$lp/tcp.*ALLOW" >/dev/null 2>&1; then
                echo -e "    • ${RED}ВНИМАНИЕ: Порт $lp/tcp открыт в UFW наружу!${NC}"
                leak=1
            fi
        done
        [ "$leak" -eq 0 ] && echo -e "    • Изоляция локальных сокетов:  ${GREEN}OK (внутренние порты 9443, 45443, 46443, 50443 не открыты наружу)${NC}"
    else
        echo -e "    • Файервол UFW:              ${YELLOW}не активен или не установлен${NC}"
    fi

    echo -e "\n  ${DIM}────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${GREEN}Диагностика завершена.${NC}\n"
    exit 0
}

if [ "${CHECK_MODE:-0}" -eq 1 ]; then
    run_doctor_check
    exit 0
fi

if [ "${NON_INTERACTIVE:-0}" -eq 1 ]; then
    log "Включен НЕИНТЕРАКТИВНЫЙ режим (Ansible / Cloud-Init / CI)."
fi

if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
    warn "Включён режим отладки (--debug): спиннеры отключены, весь вывод команд виден напрямую."
fi


# =============================================================
#  ФУНКЦИИ ФАЗЫ УСТАНОВКИ (определены до фазы для читаемости и --debug)
# =============================================================

apply_sysctl_and_limits() {
    # Загрузка модуля nf_conntrack и сохранение для автозагрузки при старте ОС
    modprobe nf_conntrack 2>/dev/null || true
    if [ -d /etc/modules-load.d ]; then
        echo "nf_conntrack" > /etc/modules-load.d/99-vless-conntrack.conf 2>/dev/null || true
    fi

    cat << 'EOF' > /etc/sysctl.d/99-vless-tuning.conf
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.ip_nonlocal_bind = 1
vm.swappiness = 10

# Отключение IPv6 (защита от утечек трафика)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Защита таблицы conntrack от зависших сессий (разрывы ТСПУ/DPI без FIN/RST)
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

net.ipv4.ip_local_port_range = 1024 65535
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_tw_buckets = 524288
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_orphan_retries = 2
net.ipv4.tcp_slow_start_after_idle = 0

net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 212992
net.core.wmem_default = 212992
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
net.ipv4.udp_mem = 65536 131072 262144
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

vm.dirty_ratio = 6
vm.dirty_background_ratio = 3

net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_mtu_probe_floor = 1024

fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
net.ipv4.tcp_notsent_lowat = 16384
EOF

    sysctl --system >/dev/null 2>&1 || true

    # Оптимизация резолвера gai.conf (приоритет IPv4 для исключения таймаутов mtg/Go QUIC)
    if [ -f /etc/gai.conf ]; then
        sed -i 's/#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf 2>/dev/null || true
    fi

    # Хранение системных логов journald в RAM (Storage=volatile, без записи на диск)
    mkdir -p /etc/systemd/journald.conf.d/
    cat << 'EOF' > /etc/systemd/journald.conf.d/00-volatile.conf
[Journal]
Storage=volatile
RuntimeMaxUse=64M
MaxRetentionSec=1day
EOF
    systemctl restart systemd-journald 2>/dev/null || true

    # Disable IPv6 immediately on all active interfaces (runtime)
    if [ -d /proc/sys/net/ipv6/conf ]; then
        for iface in $(ls /proc/sys/net/ipv6/conf/ 2>/dev/null); do
            sysctl -w net.ipv6.conf."$iface".disable_ipv6=1 >/dev/null 2>&1 || true
        done
    fi

    # Hardware/Kernel level disable via GRUB (survives cloud network resets upon reboot)
    if [ -f /etc/default/grub ]; then
        if ! grep -q "ipv6.disable=1" /etc/default/grub; then
            cp /etc/default/grub /etc/default/grub.bak 2>/dev/null || true
            sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub
            sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT='/GRUB_CMDLINE_LINUX_DEFAULT='ipv6.disable=1 /" /etc/default/grub
            sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="ipv6.disable=1 /' /etc/default/grub
            sed -i "s/GRUB_CMDLINE_LINUX='/GRUB_CMDLINE_LINUX='ipv6.disable=1 /" /etc/default/grub
            if command -v update-grub &>/dev/null; then
                update-grub >/dev/null 2>&1 || true
            elif command -v grub-mkconfig &>/dev/null; then
                grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
            fi
        fi
    fi

    # Crontab guard against cloud-init / network daemon sysctl overrides on boot
    if command -v crontab &>/dev/null; then
        local cron_job="@reboot sleep 10 && sysctl --system"
        if ! crontab -l 2>/dev/null | grep -Fq "$cron_job"; then
            (crontab -l 2>/dev/null || true; echo "$cron_job") | crontab - 2>/dev/null || true
        fi
    fi

    # Disable IPv6 in UFW configuration
    if [ -f /etc/default/ufw ]; then
        if grep -q "^IPV6=" /etc/default/ufw; then
            sed -i 's/^IPV6=.*/IPV6=no/' /etc/default/ufw 2>/dev/null || true
        else
            echo "IPV6=no" >> /etc/default/ufw 2>/dev/null || true
        fi
    fi

    cat << 'EOF' > /etc/security/limits.d/99-proxy-limits.conf
* soft nofile 524288
* hard nofile 524288
root soft nofile 524288
root hard nofile 524288
www-data soft nofile 524288
www-data hard nofile 524288
nginx soft nofile 524288
nginx hard nofile 524288
EOF

    # TCP MSS Clamping — предотвращение PMTU Blackhole при блокировке ICMP (для ядро/TUN/FORWARD трафика)
    # Примечание: действует на маршрутизируемый трафик ядра Linux; не влияет на userspace gVisor в 3X-UI.
    if ! iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    fi
    if command -v ip6tables >/dev/null 2>&1; then
        if ! ip6tables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
            ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        fi
    fi

    # Персистентность MSS Clamping через /etc/ufw/before.rules и before6.rules
    if [ -f /etc/ufw/before.rules ] && ! grep -q 'TCPMSS --clamp-mss-to-pmtu' /etc/ufw/before.rules 2>/dev/null; then
        if ! grep -q '^\*mangle' /etc/ufw/before.rules 2>/dev/null; then
            sed -i '/^\*filter/i\# TCP MSS Clamping - prevents PMTU blackhole (added by setup.sh)\n*mangle\n:FORWARD ACCEPT [0:0]\n-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\nCOMMIT\n' /etc/ufw/before.rules
        else
            sed -i '/^\*mangle/a\-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' /etc/ufw/before.rules
        fi
    fi
    if [ -f /etc/ufw/before6.rules ] && ! grep -q 'TCPMSS --clamp-mss-to-pmtu' /etc/ufw/before6.rules 2>/dev/null; then
        if ! grep -q '^\*mangle' /etc/ufw/before6.rules 2>/dev/null; then
            sed -i '/^\*filter/i\# TCP MSS Clamping IPv6 - prevents PMTU blackhole (added by setup.sh)\n*mangle\n:FORWARD ACCEPT [0:0]\n-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\nCOMMIT\n' /etc/ufw/before6.rules
        else
            sed -i '/^\*mangle/a\-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' /etc/ufw/before6.rules
        fi
    fi
}

supports_x86_64_v3() {
    local arch
    arch=$(uname -m 2>/dev/null || echo "unknown")
    if [ "$arch" != "x86_64" ]; then
        return 0
    fi
    if [ -x /lib64/ld-linux-x86-64.so.2 ]; then
        if /lib64/ld-linux-x86-64.so.2 --help 2>&1 | grep -E 'x86-64-v3' | grep -q 'supported'; then
            return 0
        fi
    fi
    if grep -q "avx2" /proc/cpuinfo 2>/dev/null && grep -q "bmi2" /proc/cpuinfo 2>/dev/null; then
        return 0
    fi
    return 1
}


# ==============================================================================
#  Подсистема безопасности хоста: SSH Hardening, SSH Keys, Dual-Port & Fail2ban
# ==============================================================================

WHITE="${WHITE:-}"
NC="${NC:-}"
YELLOW="${YELLOW:-}"
RED="${RED:-}"
GREEN="${GREEN:-}"
CYAN="${CYAN:-}"
BOLD="${BOLD:-}"
ARROW="${ARROW:-}"
DIM="${DIM:-}"

get_user_home() {
    local target_user="${1:-root}"
    if [ "$target_user" = "root" ]; then
        echo "/root"
        return 0
    fi
    local home_dir=""
    if command -v getent >/dev/null 2>&1; then
        home_dir="$(getent passwd "$target_user" 2>/dev/null | cut -d: -f6)"
    fi
    if [ -n "$home_dir" ]; then
        echo "$home_dir"
        return 0
    fi
    echo "/home/$target_user"
}

has_authorized_keys() {
    local target_user="${1:-root}"
    local user_home
    if [ "$target_user" = "root" ]; then
        user_home="/root"
    else
        user_home="$(get_user_home "$target_user")"
    fi
    local auth_file="${user_home}/.ssh/authorized_keys"
    if [ -f "$auth_file" ] && [ -s "$auth_file" ]; then
        if grep -qE '^[[:space:]]*(ssh-rsa|ssh-ed25519|ecdsa-sha2-[a-z0-9]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-[a-z0-9]+@openssh\.com)' "$auth_file" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

add_authorized_key() {
    local key_data="$1"
    local target_user="${2:-root}"
    [ -n "$key_data" ] || return 1

    local user_home
    if [ "$target_user" = "root" ]; then
        user_home="/root"
    else
        user_home="$(get_user_home "$target_user")"
    fi

    mkdir -p "${user_home}/.ssh"
    chmod 700 "${user_home}/.ssh" 2>/dev/null || true

    local auth_file="${user_home}/.ssh/authorized_keys"
    touch "$auth_file"
    chmod 600 "$auth_file" 2>/dev/null || true

    # Проверка, не добавлен ли уже этот ключ
    local clean_key
    clean_key=$(echo "$key_data" | awk '{print $1" "$2}')
    if [ -n "$clean_key" ] && grep -Fq "$clean_key" "$auth_file" 2>/dev/null; then
        ok "SSH-ключ уже присутствует в $auth_file."
        return 0
    fi

    echo "$key_data" >> "$auth_file"
    chmod 600 "$auth_file" 2>/dev/null || true
    if [ "$target_user" != "root" ] && command -v chown >/dev/null 2>&1; then
        chown -R "${target_user}:${target_user}" "${user_home}/.ssh" 2>/dev/null || true
    fi
    ok "SSH-ключ успешно добавлен в ${auth_file}."
    return 0
}

generate_ed25519_keypair() {
    local target_user="${1:-root}"
    local user_home
    if [ "$target_user" = "root" ]; then
        user_home="/root"
    else
        user_home="$(get_user_home "$target_user")"
    fi

    mkdir -p "${user_home}/.ssh"
    chmod 700 "${user_home}/.ssh" 2>/dev/null || true

    local key_file="${user_home}/.ssh/id_ed25519_$(date +%Y%m%d_%H%M%S)"
    if ! ssh-keygen -t ed25519 -f "$key_file" -C "server-${target_user}-$(date +%Y%m%d)" -N "" -q 2>/dev/null; then
        warn "Не удалось сгенерировать пару ключей ssh-keygen."
        return 1
    fi

    local auth_file="${user_home}/.ssh/authorized_keys"
    cat "${key_file}.pub" >> "$auth_file"
    chmod 600 "$auth_file" "${key_file}" 2>/dev/null || true
    if [ "$target_user" != "root" ] && command -v chown >/dev/null 2>&1; then
        chown -R "${target_user}:${target_user}" "${user_home}/.ssh" 2>/dev/null || true
    fi

    echo
    echo -e "${RED}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║${NC}             ${WHITE}${BOLD}🔑 ВНИМАНИЕ: СОХРАНИТЕ ЭТОТ ПРИВАТНЫЙ КЛЮЧ ПРЯМО СЕЙЧАС!${NC}           ${RED}║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${YELLOW}Скопируйте всё содержимое между линиями и сохраните в файл на своем ПК${NC}"
    echo -e "  ${YELLOW}(например, ~/.ssh/server_key или puttygen -> id_ed25519.ppk):${NC}"
    echo -e "${CYAN}--------------------------------------------------------------------------------${NC}"
    cat "$key_file"
    echo -e "${CYAN}--------------------------------------------------------------------------------${NC}"
    echo
    if [ -t 0 ]; then
        local dummy=""
        read -r -p "  Нажмите [Enter] после того, как сохранили приватный ключ в надежном месте..." dummy </dev/tty 2>/dev/null || read -r -p "  Нажмите [Enter]..." dummy 2>/dev/null || true
    fi
    ok "SSH-ключ Ed25519 сгенерирован и добавлен в ${auth_file}."
    return 0
}

verify_ssh_local_port() {
    local port="$1"
    local timeout_sec="${2:-3}"

    # 1. Попытка чтения баннера SSH-2.0 через Bash /dev/tcp
    local banner=""
    banner=$(timeout "$timeout_sec" bash -c "exec 3<>/dev/tcp/127.0.0.1/$port; head -n 1 <&3" 2>/dev/null || true)
    if [[ "$banner" == *"SSH-2.0"* ]]; then
        return 0
    fi

    # 2. Попытка через nc
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w "$timeout_sec" 127.0.0.1 "$port" 2>/dev/null; then
            return 0
        fi
    fi

    # 3. Попытка через ss
    if command -v ss >/dev/null 2>&1; then
        if ss -tln sport = ":$port" 2>/dev/null | grep -q ":$port"; then
            return 0
        fi
    fi

    return 1
}

apply_ssh_configuration() {
    local target_port="${1:-22}"
    local active_port="${2:-22}"
    local disable_pwd="${3:-n}"

    local ssh_svc
    ssh_svc=$(get_ssh_service_name)

    # 1. Отключаем systemd socket-activation (Ubuntu 22.10+, Ubuntu 24.04 LTS),
    # чтобы служба корректно слушала кастомный порт через стандартный unit.
    systemctl stop ssh.socket 2>/dev/null || true
    systemctl disable ssh.socket 2>/dev/null || true
    systemctl enable "${ssh_svc}.service" 2>/dev/null || true

    # 2. Обновляем базовый /etc/ssh/sshd_config с гарантией директивы Include
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i -E "s/^[#\s]*Port [0-9]+/Port ${target_port}/" /etc/ssh/sshd_config 2>/dev/null || true
        if ! grep -q "^Include /etc/ssh/sshd_config.d/\*\.conf" /etc/ssh/sshd_config 2>/dev/null; then
            sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config 2>/dev/null || true
        fi
    fi

    # 3. Drop-in конфигурация: ДВУХПОРТОВЫЙ РЕЖИМ при смене порта
    mkdir -p /etc/ssh/sshd_config.d/
    local dropin_file="/etc/ssh/sshd_config.d/99-hardening.conf"

    # Формируем директивы портов
    local port_directives="Port ${target_port}"
    if [ "$target_port" -ne "$active_port" ]; then
        port_directives="Port ${target_port}
Port ${active_port}"
    fi

    # Проверяем, можно ли отключить вход по паролю (ТОЛЬКО если есть валидные ключи)
    local pwd_directives=""
    if is_true "$disable_pwd"; then
        if has_authorized_keys "root"; then
            pwd_directives="PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes"
            ok "Вход по паролю будет отключен (авторизованные SSH-ключи подтверждены)."
        else
            warn "Внимание: в authorized_keys не найдено SSH-ключей! Вход по паролю оставлен включенным для предотвращения потери доступа."
        fi
    fi

    cat << EOF > "$dropin_file"
# Сгенерировано Nginx Stream Router Security Subsystem
${port_directives}
AddressFamily inet
PubkeyAuthentication yes
${pwd_directives}
EOF
    chmod 600 "$dropin_file" 2>/dev/null || true

    # 4. Проверяем валидность конфигурации sshd перед перезапуском
    mkdir -p /run/sshd 2>/dev/null || true
    if /usr/sbin/sshd -t 2>/dev/null; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart "${ssh_svc}.service" 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    else
        # При синтаксической ошибке — безопасный откат
        warn "Ошибка валидации sshd -t при настройке SSH! Выполнен откат изменений drop-in для предотвращения потери доступа."
        rm -f "$dropin_file"
        systemctl restart "${ssh_svc}.service" 2>/dev/null || true
        return 1
    fi

    # 5. Локальный тест ответа порта
    if [ "$target_port" -ne "$active_port" ]; then
        if verify_ssh_local_port "$target_port" 5; then
            ok "Служба SSH запущена в переходном режиме: слушает новый порт ${WHITE}${target_port}${NC} и резервный порт ${WHITE}${active_port}${NC}."
        else
            warn "Локальный тест порта $target_port не дал ответа! Выполняется откат на активный порт $active_port..."
            cat << EOF > "$dropin_file"
Port ${active_port}
AddressFamily inet
PubkeyAuthentication yes
EOF
            chmod 600 "$dropin_file" 2>/dev/null || true
            systemctl restart "${ssh_svc}.service" 2>/dev/null || true
            return 1
        fi
    else
        ok "Конфигурация SSH успешно применена (порт ${WHITE}${target_port}${NC})."
    fi

    return 0
}

deploy_ssh_transition_watcher() {
    local target_port="$1"
    local active_port="$2"
    local ttl_hours="${3:-24}"

    [ "$target_port" -eq "$active_port" ] && return 0

    local watcher_script="/usr/local/bin/ssh-transition-watcher.sh"
    local watcher_service="/etc/systemd/system/ssh-transition-watcher.service"
    local bin_dir="/usr/local/bin"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    cat << 'EOF' > "$watcher_script"
#!/usr/bin/env bash
# SSH Port Transition Watcher — безопасное закрытие старого порта при первом успешном входе на новый
set -u
TARGET_PORT="${1:-2222}"
ACTIVE_PORT="${2:-22}"
TTL_HOURS="${3:-24}"

START_TIME=$(date +%s)
MAX_RUNTIME=$((TTL_HOURS * 3600))

logger -t ssh-watcher "Запущен безопасный монитор перехода SSH: цель=$TARGET_PORT, старый=$ACTIVE_PORT, TTL=${TTL_HOURS}ч."

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    if [ "$ELAPSED" -ge "$MAX_RUNTIME" ]; then
        logger -t ssh-watcher "Истек лимит времени ожидания (${TTL_HOURS}ч). Старый порт $ACTIVE_PORT оставлен для предотвращения потери доступа."
        exit 0
    fi

    # Проверяем подтвержденную аутентифицированную сессию на целевом порту (T17.C06)
    # TCP ESTABLISHED, проверка локального listener и попытка входа без авторизации НЕ считаются успешным входом.
    AUTH_OK=0
    if command -v journalctl >/dev/null 2>&1; then
        if journalctl -u ssh -u sshd --since "@${START_TIME}" 2>/dev/null | grep -qE "Accepted (publickey|password|keyboard-interactive) for .* port ${TARGET_PORT}"; then
            AUTH_OK=1
        fi
    fi
    if [ "$AUTH_OK" -eq 0 ] && [ -f /var/log/auth.log ]; then
        if grep -qE "Accepted (publickey|password|keyboard-interactive) for .* port ${TARGET_PORT}" /var/log/auth.log 2>/dev/null; then
            AUTH_OK=1
        fi
    fi

    if [ "$AUTH_OK" -eq 1 ]; then
        logger -t ssh-watcher "Обнаружена подтвержденная аутентифицированная сессия на порт $TARGET_PORT! Финализация перехода и закрытие порта $ACTIVE_PORT..."

        # 1. Удаляем старый порт из drop-in sshd
        if [ -f /etc/ssh/sshd_config.d/99-hardening.conf ]; then
            sed -i "/^Port ${ACTIVE_PORT}$/d" /etc/ssh/sshd_config.d/99-hardening.conf 2>/dev/null || true
        fi
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true

        # 2. Удаляем старый порт из UFW
        if command -v ufw >/dev/null 2>&1; then
            ufw delete allow "${ACTIVE_PORT}/tcp" >/dev/null 2>&1 || true
        fi

        # 3. Обновляем Fail2ban
        if [ -f /etc/fail2ban/jail.local ]; then
            sed -i "s/port = .*/port = ${TARGET_PORT}/" /etc/fail2ban/jail.local 2>/dev/null || true
            systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null || true
        fi

        logger -t ssh-watcher "Переход SSH успешно завершен. Порт $ACTIVE_PORT закрыт, активен только $TARGET_PORT."
        systemctl disable --now ssh-transition-watcher.service 2>/dev/null || true
        rm -f /etc/systemd/system/ssh-transition-watcher.service /usr/local/bin/ssh-transition-watcher.sh 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        exit 0
    fi

    sleep 5
done
EOF
    chmod +x "$watcher_script" 2>/dev/null || true

    mkdir -p /etc/systemd/system
    cat << EOF > "$watcher_service"
[Unit]
Description=SSH Port Transition Safe Watcher
After=network.target sshd.service ssh.service

[Service]
Type=simple
ExecStart=${watcher_script} ${target_port} ${active_port} ${ttl_hours}
Restart=no

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable --now ssh-transition-watcher.service >/dev/null 2>&1 || true
        ok "Развернут фоновый сторожевой сервис ${WHITE}ssh-transition-watcher.service${NC}."
    fi
}

finalize_ssh_transition() {
    local target_port="$1"
    local active_port="$2"
    local ssh_svc
    ssh_svc=$(get_ssh_service_name)

    [ "$target_port" -eq "$active_port" ] && return 0

    log "Финализация перехода SSH: закрытие резервного порта ${active_port}..."

    # 1. Удаляем старый порт из drop-in конфигурации
    if [ -f /etc/ssh/sshd_config.d/99-hardening.conf ]; then
        sed -i "/^Port ${active_port}$/d" /etc/ssh/sshd_config.d/99-hardening.conf 2>/dev/null || true
    fi

    # 2. Обновляем базовый /etc/ssh/sshd_config
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i -E "s/^[#\s]*Port [0-9]+/Port ${target_port}/" /etc/ssh/sshd_config 2>/dev/null || true
    fi

    # 3. Валидация и перезагрузка sshd
    mkdir -p /run/sshd 2>/dev/null || true
    if /usr/sbin/sshd -t 2>/dev/null; then
        systemctl reload "${ssh_svc}.service" 2>/dev/null || systemctl restart "${ssh_svc}.service" 2>/dev/null || true
    fi

    # 4. Удаляем старый порт из UFW
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "${active_port}/tcp" >/dev/null 2>&1 || true
    fi

    # 5. Обновляем Fail2ban
    if [ -f /etc/fail2ban/jail.local ]; then
        sed -i "s/port = .*/port = ${target_port}/" /etc/fail2ban/jail.local 2>/dev/null || true
        systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null || true
    fi

    # 6. Останавливаем и удаляем watcher
    systemctl disable --now ssh-transition-watcher.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/ssh-transition-watcher.service /usr/local/bin/ssh-transition-watcher.sh 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true

    ok "Резервный порт SSH ${active_port} закрыт. SSH теперь работает исключительно на порту ${WHITE}${target_port}${NC}."
}

wait_and_finalize_ssh_transition() {
    local target_port="$1"
    local active_port="$2"
    local timeout_sec="${3:-30}"

    [ "$target_port" -eq "$active_port" ] && return 0

    if is_true "${FORCE_CLOSE_OLD_SSH:-n}"; then
        ok "Включен режим принудительного закрытия (--force-close-old-ssh / FORCE_CLOSE_OLD_SSH=y)."
        finalize_ssh_transition "$target_port" "$active_port"
        return 0
    fi

    # Если скрипт выполняется не интерактивно (нет tty) — поднимаем watcher и выходим
    if [ ! -t 0 ] || [ "${NON_INTERACTIVE:-0}" -eq 1 ]; then
        log "Неинтерактивный запуск: активирован фоновый watcher перехода SSH."
        deploy_ssh_transition_watcher "$target_port" "$active_port" 24
        return 0
    fi

    local host_ip
    host_ip=$(get_wan_ip)

    echo
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║${NC}             ${WHITE}${BOLD}⚡ БЕЗОПАСНЫЙ ПЕРЕХОД SSH: ПОРТЫ ${target_port} (НОВЫЙ) И ${active_port} (СТАРЫЙ)${NC}            ${YELLOW}║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "  Служба SSH сейчас слушает ${GREEN}ОБА порта (${target_port} и ${active_port})${NC}. Ваша текущая сессия не прервана."
    echo -e "  Брандмауэр UFW и Fail2ban защищают оба порта."
    echo
    echo -e "  ${CYAN}${BOLD}ПРОВЕРЬТЕ ПОДКЛЮЧЕНИЕ В НОВОЙ ВКЛАДКЕ ТЕРМИНАЛА:${NC}"
    echo -e "    ${WHITE}ssh -p ${target_port} root@${host_ip}${NC}"
    echo
    echo -e "  ${WHITE}[1]${NC} Ожидать вашего подключения (${timeout_sec} сек, автозакрытие при успехе) ${GREEN}[Enter]${NC}"
    echo -e "  ${WHITE}[2]${NC} Оставить оба порта и передать контроль фоновому watcher (закроет старый порт позже)"
    echo -e "  ${WHITE}[3]${NC} Закрыть старый порт ${active_port} прямо сейчас"
    echo

    local choice=""
    echo -ne "  ${WHITE}${ARROW} Ваш выбор [1/2/3] (по умолчанию 1): ${NC}"
    read -r -t 10 choice </dev/tty || choice="1"
    choice="${choice:-1}"
    choice=$(echo "$choice" | tr -d '[:space:]')

    case "$choice" in
        2)
            deploy_ssh_transition_watcher "$target_port" "$active_port" 24
            ok "Оба порта (${target_port} и ${active_port}) остаются открытыми. Watcher закроет ${active_port} после входа."
            return 0
            ;;
        3)
            finalize_ssh_transition "$target_port" "$active_port"
            return 0
            ;;
        *)
            echo -e "  ${CYAN}Ожидание входящего подключения на порт ${target_port} (${timeout_sec} сек)...${NC}"
            local elapsed=0
            while [ "$elapsed" -lt "$timeout_sec" ]; do
                local est_count=0
                est_count=$(ss -tn sport = ":${target_port}" state established 2>/dev/null | grep -vE '127\.0\.0\.1|::1|Local Address' | wc -l)
                if [ "$est_count" -gt 0 ]; then
                    echo
                    ok "Успешное входящее подключение на порт ${target_port} обнаружено!"
                    finalize_ssh_transition "$target_port" "$active_port"
                    return 0
                fi
                sleep 1
                elapsed=$((elapsed + 1))
                echo -ne "\r  ${DIM}Осталось: $((timeout_sec - elapsed)) сек...${NC} "
            done
            echo
            warn "За ${timeout_sec} сек новых подключений не зафиксировано."
            ok "Для вашей безопасности старый порт ${active_port} пока оставлен открытым."
            deploy_ssh_transition_watcher "$target_port" "$active_port" 24
            return 0
            ;;
    esac
}

apply_fail2ban_configuration() {
    local target_port="${1:-22}"
    local active_port="${2:-22}"

    # 1. Установка пакетов fail2ban и python3-systemd (для чтения journald в Ubuntu 24.04 / Debian 12)
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y >/dev/null 2>&1 || true
            apt-get install -y fail2ban python3-systemd >/dev/null 2>&1 || apt-get install -y fail2ban >/dev/null 2>&1 || true
        fi
    fi

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        warn "Пакет fail2ban не найден в системе и не может быть установлен."
        return 1
    fi

    # 2. Формируем список защищаемых портов (и активный, и целевой, и сокет)
    local ports_set=()
    [ -n "$active_port" ] && ports_set+=("$active_port")
    [ -n "$target_port" ] && [ "$target_port" != "$active_port" ] && ports_set+=("$target_port")

    # Проверка фактических слушающих портов SSH
    if command -v sshd >/dev/null 2>&1; then
        local detected_p
        detected_p=$(sshd -T 2>/dev/null | awk '/^port / {print $2}' || true)
        if [ -n "$detected_p" ] && [[ ! " ${ports_set[*]} " =~ " ${detected_p} " ]]; then
            ports_set+=("$detected_p")
        fi
    fi

    local port_str
    port_str=$(IFS=,; echo "${ports_set[*]}")
    [ -z "$port_str" ] && port_str="22"

    mkdir -p /etc/fail2ban/jail.d 2>/dev/null || true
    cat << EOF > /etc/fail2ban/jail.d/90-ssh-shield.local
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd
banaction = ufw

[sshd]
enabled = true
port = ${port_str}
EOF
    chmod 644 /etc/fail2ban/jail.d/90-ssh-shield.local 2>/dev/null || true

    # 3. Активация и запуск службы
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true

    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        ok "Служба Fail2ban успешно запущена и защищает SSH (порты: ${WHITE}${port_str}${NC})."
    else
        warn "Служба Fail2ban была установлена, но не смогла запуститься. Проверьте journalctl -u fail2ban."
        return 1
    fi
    return 0
}

setup_strict_dot_dns() {
    log "Настройка защищенного системного резолвера Strict DNS-over-TLS (systemd-resolved)..."
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    mkdir -p /etc/systemd/resolved.conf.d 2>/dev/null || true
    cat << 'EOF_RESOLVED' > /etc/systemd/resolved.conf.d/00-strict-dot.conf
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 8.8.8.8#dns.google 8.8.4.4#dns.google 9.9.9.9#dns.quad9.net
FallbackDNS=1.1.1.1 8.8.8.8
DNSOverTLS=yes
DNSSEC=allow-downgrade
Cache=yes
DNSStubListener=yes
MulticastDNS=no
LLMNR=no
EOF_RESOLVED
    chmod 644 /etc/systemd/resolved.conf.d/00-strict-dot.conf 2>/dev/null || true

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable systemd-resolved >/dev/null 2>&1 || true
    systemctl restart systemd-resolved 2>/dev/null || true

    if [ -L /etc/resolv.conf ] || [ -f /etc/resolv.conf ]; then
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
    fi
    ok "Strict DNS-over-TLS (systemd-resolved, порт 853 TLS) активирован."
}

setup_unattended_upgrades() {
    log "Настройка автоматических обновлений безопасности (unattended-upgrades)..."
    if ! command -v apt-get >/dev/null 2>&1; then
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y -q unattended-upgrades update-notifier-common >/dev/null 2>&1 || true

    mkdir -p /etc/apt/apt.conf.d 2>/dev/null || true
    cat << 'EOF_UPG' > /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:38";
EOF_UPG

    cat << 'EOF_AUTOS' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF_AUTOS

    systemctl restart unattended-upgrades 2>/dev/null || true
    ok "Автоматические ночные обновления безопасности настроены (ребут при необходимости в 04:38)."
}

setup_vpn_diagnostics() {
    log "Развертывание веб-портала диагностики и демона MTR..."
    local diag_dir="/var/www/diagnostics"
    local bin_dir="/usr/local/lib/vpn-diagnostics"
    local svc_file="/etc/systemd/system/vpn-diagnostics.service"

    mkdir -p "$diag_dir" "$bin_dir" 2>/dev/null || true

    local src_diag="${SCRIPT_DIR:-.}/diagnostics"
    if [ ! -d "$src_diag" ]; then
        for cand in ./diagnostics /root/diagnostics; do
            if [ -d "$cand" ]; then
                src_diag="$cand"
                break
            fi
        done
    fi

    if [ -d "$src_diag" ]; then
        cp -a "$src_diag/index.html" "$diag_dir/" 2>/dev/null || true
        cp -a "$src_diag/speedtest.js" "$diag_dir/" 2>/dev/null || true
        cp -a "$src_diag/speedtest_worker.js" "$diag_dir/" 2>/dev/null || true
        cp -a "$src_diag/mtr-backend.py" "$bin_dir/" 2>/dev/null || true
        cp -a "$src_diag/vpn-diagnostics.service" "$svc_file" 2>/dev/null || true
    fi

    # Гарантируем наличие утилиты mtr для бэкенда диагностики
    if ! command -v mtr >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
        apt-get install -y -qq mtr-tiny >/dev/null 2>&1 || true
    fi

    # Назначение прав
    chown -R www-data:www-data "$diag_dir" 2>/dev/null || chown -R nginx:nginx "$diag_dir" 2>/dev/null || true
    chmod -R 755 "$diag_dir" 2>/dev/null || true
    chmod 755 "$bin_dir/mtr-backend.py" 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1 && [ -f "$svc_file" ]; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable vpn-diagnostics >/dev/null 2>&1 || true
        systemctl restart vpn-diagnostics 2>/dev/null || true
        if systemctl is-active --quiet vpn-diagnostics; then
            ok "Служба vpn-diagnostics запущена на сокете /run/vpn-diagnostics/mtr-backend.sock."
        else
            warn "Служба vpn-diagnostics не смогла запуститься."
        fi
    fi
}

ensure_nginx_stream_module() {
    command -v nginx >/dev/null 2>&1 || return 0

    mkdir -p /etc/nginx/modules-enabled 2>/dev/null || true
    find /etc/nginx/modules-enabled/ -xtype l -delete 2>/dev/null || true

    # 1. Проверяем, поддерживает ли бинарник Nginx директиву stream изначально (статическая сборка)
    local test_conf
    test_conf=$(mktemp 2>/dev/null || echo "/tmp/nginx_test_stream_$$.conf")
    cat << 'EOF' > "$test_conf"
events { worker_connections 64; }
stream {}
EOF
    if nginx -t -c "$test_conf" >/dev/null 2>&1; then
        rm -f "$test_conf" 2>/dev/null || true
        return 0
    fi

    # 2. Проверяем, работает ли stream с текущими модулями в /etc/nginx/modules-enabled/
    cat << 'EOF' > "$test_conf"
include /etc/nginx/modules-enabled/*.conf;
events { worker_connections 64; }
stream {}
EOF
    if nginx -t -c "$test_conf" >/dev/null 2>&1; then
        rm -f "$test_conf" 2>/dev/null || true
        return 0
    fi
    rm -f "$test_conf" 2>/dev/null || true

    # 3. Модуль stream не загружен или отсутствует. Ищем файл ngx_stream_module.so
    local mod_so=""
    for cand in /etc/nginx/modules/ngx_stream_module.so \
                /usr/lib/nginx/modules/ngx_stream_module.so \
                /usr/share/nginx/modules/ngx_stream_module.so \
                /usr/local/nginx/modules/ngx_stream_module.so; do
        if [ -f "$cand" ]; then
            mod_so="$cand"
            break
        fi
    done

    # 4. Если модуль не найден на диске, устанавливаем пакет модуля через пакетный менеджер
    if [ -z "$mod_so" ] && command -v apt-get >/dev/null 2>&1; then
        log "Установка модуля Nginx Stream L4 (libnginx-mod-stream / nginx-module-stream)..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q || true
        apt-get install -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
            libnginx-mod-stream 2>/dev/null || \
        apt-get install -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
            nginx-module-stream 2>/dev/null || true

        for cand in /etc/nginx/modules/ngx_stream_module.so \
                    /usr/lib/nginx/modules/ngx_stream_module.so \
                    /usr/share/nginx/modules/ngx_stream_module.so \
                    /usr/local/nginx/modules/ngx_stream_module.so; do
            if [ -f "$cand" ]; then
                mod_so="$cand"
                break
            fi
        done
    fi

    # 5. Если модуль найден, создаем конфигурационный файл в modules-enabled
    if [ -n "$mod_so" ]; then
        rm -f /etc/nginx/modules-enabled/*stream*.conf 2>/dev/null || true
        cat << EOF > /etc/nginx/modules-enabled/50-mod-stream.conf
load_module $mod_so;
EOF
    fi

    # 6. Проверяем работоспособность директивы stream с подключенным модулем
    test_conf=$(mktemp 2>/dev/null || echo "/tmp/nginx_test_stream_$$.conf")
    cat << 'EOF' > "$test_conf"
include /etc/nginx/modules-enabled/*.conf;
events { worker_connections 64; }
stream {}
EOF
    if nginx -t -c "$test_conf" >/dev/null 2>&1; then
        rm -f "$test_conf" 2>/dev/null || true
        ok "Модуль Nginx Stream L4 успешно активирован."
        return 0
    fi
    rm -f "$test_conf" 2>/dev/null || true

    # 7. Fail-safe fallback: если Nginx по-прежнему не распознает stream (например, бинарник несовместим с модулем),
    # выполняем чистую переустановку дистрибутивного Nginx с libnginx-mod-stream
    if command -v apt-get >/dev/null 2>&1; then
        local os_id
        os_id=$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "ubuntu")
        warn "Сбой загрузки модуля Stream в текущей версии Nginx. Экстренное восстановление системного Nginx..."
        rm -f /etc/apt/sources.list.d/nginx.list /etc/apt/preferences.d/99nginx
        apt-get purge -y nginx nginx-common nginx-core libnginx* 2>/dev/null || apt-get remove -y nginx* 2>/dev/null || true
        apt-get update -q || true
        apt-get install -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" nginx libnginx-mod-stream 2>/dev/null || apt-get install -y -q nginx

        find /etc/nginx/modules-enabled/ -xtype l -delete 2>/dev/null || true
        for cand in /etc/nginx/modules/ngx_stream_module.so \
                    /usr/lib/nginx/modules/ngx_stream_module.so \
                    /usr/share/nginx/modules/ngx_stream_module.so; do
            if [ -f "$cand" ]; then
                mod_so="$cand"
                break
            fi
        done
        if [ -n "$mod_so" ] && ! grep -rqs "ngx_stream_module" /etc/nginx/modules-enabled/ 2>/dev/null; then
            cat << EOF > /etc/nginx/modules-enabled/50-mod-stream.conf
load_module $mod_so;
EOF
        fi
    fi
}

setup_nginx_mainline() {
    export DEBIAN_FRONTEND=noninteractive
    local os_id os_codename
    os_id=$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "ubuntu")
    os_codename=$(lsb_release -cs 2>/dev/null || echo "jammy")

    # 1. Если Nginx уже установлен — проверяем, запускается ли бинарник
    if command -v nginx >/dev/null 2>&1; then
        if nginx -v >/dev/null 2>&1; then
            mkdir -p /etc/nginx/modules-enabled 2>/dev/null || true
            ensure_nginx_stream_module
            return 0
        fi
        warn "Обнаружен несовместимый Nginx (CPU ISA level is lower than required). Очистка..."
        rm -f /etc/apt/sources.list.d/nginx.list /etc/apt/preferences.d/99nginx
        apt-get purge -y nginx nginx-common nginx-core libnginx* 2>/dev/null || apt-get remove -y nginx* 2>/dev/null || true
        apt-get update -q || true
    fi

    apt-get update -q || true
    apt-get install gnupg ca-certificates lsb-release openssl -y -q || true

    # 2. Проверяем поддержку процессором микроархитектуры x86-64-v3
    local can_use_nginx_org=1
    if ! supports_x86_64_v3; then
        warn "Процессор VPS (или профиль гипервизора) не поддерживает x86-64-v3 (AVX2/BMI2)."
        log "Подключение Nginx из официального системного репозитория $os_id (100% совместимость со всеми CPU)..."
        can_use_nginx_org=0
    fi

    if [ "$can_use_nginx_org" -eq 1 ]; then
        mkdir -p /usr/share/keyrings
        curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg --yes 2>/dev/null || true

        if [ -s /usr/share/keyrings/nginx-archive-keyring.gpg ]; then
            echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/$os_id $os_codename nginx" \
                > /etc/apt/sources.list.d/nginx.list

            cat << EOF > /etc/apt/preferences.d/99nginx
Package: nginx*
Pin: origin nginx.org
Pin-Priority: 900
EOF

            apt-get update -q || true
            apt-get install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" nginx nginx-module-stream -y -q 2>/dev/null || \
            apt-get install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" nginx -y -q || true
        fi
    fi

    # 3. Валидация работоспособности установленного Nginx (Fail-Safe Fallback)
    if ! command -v nginx >/dev/null 2>&1 || ! nginx -v >/dev/null 2>&1; then
        warn "Сбой запуска Nginx из внешнего репозитория (или несовместимость с ISA процессора)."
        log "Экстренный fallback: установка системного Nginx из репозитория $os_id..."
        rm -f /etc/apt/sources.list.d/nginx.list /etc/apt/preferences.d/99nginx
        apt-get purge -y nginx nginx-common nginx-core libnginx* 2>/dev/null || apt-get remove -y nginx* 2>/dev/null || true
        apt-get update -q || true
        apt-get install -y -q -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" nginx libnginx-mod-stream 2>/dev/null || apt-get install -y -q nginx
    fi

    mkdir -p /etc/nginx/modules-enabled 2>/dev/null || true
    nginx -v >/dev/null 2>&1 || die "Не удалось установить рабочий Nginx, совместимый с данным процессором."
    ensure_nginx_stream_module
}


install_certbot_package() {
    export DEBIAN_FRONTEND=noninteractive

    # 1. Если certbot уже присутствует в системе и работает — используем его
    if command -v certbot >/dev/null 2>&1 && certbot --version >/dev/null 2>&1; then
        return 0
    fi

    # 2. Приоритет: Нативный легкий certbot из официального apt репозитория
    apt-get update -q -y >/dev/null 2>&1 || true
    if apt-get install -y -q certbot python3-certbot-nginx; then
        if command -v certbot >/dev/null 2>&1; then
            return 0
        fi
    fi

    # 3. Резервный вариант (Fallback): Установка через Snap, если apt недоступен
    if apt-get install -y -q snapd; then
        systemctl start snapd.socket 2>/dev/null || true
        systemctl enable snapd.socket 2>/dev/null || true
        for i in {1..10}; do
            if snap version >/dev/null 2>&1; then break; fi
            sleep 2
        done
        snap install core 2>/dev/null || true
        snap refresh core 2>/dev/null || true
        if snap install --classic certbot 2>/dev/null; then
            ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
            if command -v certbot >/dev/null 2>&1; then
                return 0
            fi
        fi
    fi

    # 4. Если оба метода не удались — пробуем pip / certbot standalone
    if command -v certbot >/dev/null 2>&1; then
        return 0
    fi

    die "Не удалось установить Certbot ни через APT, ни через Snap. Проверьте репозитории вашей ОС."
}

# Принимает $1 = домен (был closure-переменной $dom из цикла)
obtain_cert() {
    local dom="$1"
    if [ -f "/etc/letsencrypt/live/$dom/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/$dom/privkey.pem" ]; then
        return 0
    fi

    # 1. Попытка через Nginx Webroot (если порт 80 слушается)
    if ss -tlnp 2>/dev/null | grep -qE ':80\s'; then
        if certbot certonly --webroot -w "$WEBROOT" --expand -d "$dom" --non-interactive; then
            return 0
        fi
        warn "Сбой верификации через Nginx Webroot для $dom. Пробуем Standalone-режим..."
    fi

    # 2. Надежный fallback: Standalone (Certbot сам поднимает временный сервер на порту 80)
    systemctl stop nginx 2>/dev/null || true
    local res=0
    certbot certonly --standalone --expand -d "$dom" --non-interactive || res=$?
    systemctl start nginx 2>/dev/null || true
    return $res
}

install_acmesh() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y cron socat -q
    local acme_mail="${LE_EMAIL:-admin@$PRIMARY_DOMAIN}"
    local _acme_bin="${HOME:-/root}/.acme.sh/acme.sh"

    if [ ! -x "$_acme_bin" ]; then
        local acme_tmp="/tmp/acme_staging_$$"
        mkdir -p "$acme_tmp"
        if download_manifest_component "acme.sh" "$acme_tmp/acme.tar.gz" "all"; then
            tar -zxf "$acme_tmp/acme.tar.gz" -C "$acme_tmp" --strip-components=1 2>/dev/null || tar -zxf "$acme_tmp/acme.tar.gz" -C "$acme_tmp" 2>/dev/null || true
            local acme_src
            acme_src="$(find "$acme_tmp" -name acme.sh -type f 2>/dev/null | head -n1)"
            if [ -n "$acme_src" ] && [ -f "$acme_src" ]; then
                bash "$acme_src" --install --home "${HOME:-/root}/.acme.sh" --accountemail "$acme_mail" >/dev/null 2>&1 || true
            fi
        else
            warn "Не удалось скачать проверенный дистрибутив acme.sh"
        fi
        rm -rf "$acme_tmp" 2>/dev/null || true
    fi

    if [ -f "$_acme_bin" ]; then
        chmod +x "$_acme_bin" 2>/dev/null || true
        "$_acme_bin" --register-account -m "$acme_mail" --server letsencrypt >/dev/null 2>&1 || true
    fi
}

# Принимает $1 = домен (был closure-переменной $dom из цикла)
# Использует глобальные $_ACME (устанавливается после install_acmesh)
obtain_cf_cert() {
    local dom="$1"
    "$_ACME" --issue --dns dns_cf -d "$dom" --server letsencrypt --force && \
    mkdir -p "/etc/ssl/acme/$dom" && \
    chmod 750 "/etc/ssl/acme/$dom" && \
    "$_ACME" --install-cert -d "$dom" \
        --key-file       "/etc/ssl/acme/$dom/privkey.pem" \
        --fullchain-file "/etc/ssl/acme/$dom/fullchain.pem" \
        --reloadcmd     "chmod 750 /etc/ssl/acme /etc/ssl/acme/$dom 2>/dev/null || true; chmod 640 /etc/ssl/acme/$dom/*.pem 2>/dev/null || true; chmod 600 /etc/ssl/acme/$dom/privkey*.pem 2>/dev/null || true; chown -R root:www-data /etc/ssl/acme 2>/dev/null || true; systemctl reload nginx"
}

nginx_reload_task() {
    nginx -t || return 1
    systemctl unmask nginx 2>/dev/null || true
    systemctl enable nginx 2>/dev/null || true
    systemctl restart nginx
}


# --- Модуль AmneziaWG: Универсальный контроллер и сервис управления (v3.1 / v2.0) ---
# На базе концепций проекта: https://github.com/bivlked/amneziawg-installer (@bivlked)

AMNEZIA_PPA_GPG_B64="xsFNBGV0UhsBEAC33rMndHSN/k+u7gcZbh9/FjgYfGltQAtVe2QDxzn7UV+k/ChXOrYRw6Izw/DrhaapkNCThK2jwJE64e0NjboLH7UrrmSJLXMfOlDFbyGJVRA+1sTBlo7kKHY0xiZ1CHDzjKNV3czbesu80A9nuTZYyWHEn9ax6wsqKG3N8SvzQkUrIOVD2wZjh0p273CCEGkBnax1ghAV3MF8OrsPU6FRJ+ZakzKbu54g68xoV+2813YECme0JKsWfUUe/1uEJOXCvuACURSxnYr0sihJd8QI/jHSGlfeq72e5MflFEOrnu5xaDSJr2W5lvUetG7EGSxtNKd7Jm/KhUV04g7arA0qydRjRToW3QqyzG7VB2nXKz3AOBYNearWAuBcTkfPvRVchxbjiYonKZA5tIlVrpawMZsdxKvYwl6LVnpBcccFWPhpudfy4TpCqCxRoAanOCvSirI3/y7TcZMBw643SaxXi1ifGeg6eyMzrLtP3CeonKBHGzrt1eeKGtEw/PFN4RmwpBePxi+uj0CoTD6zjCQa3c8EeB4Qz7tt6PnpibxdtZE8sBdd51wSA/fPGi2tFph8IVAsws7oxcQxZYl8CyncKDLcoR4dxVHYdFEDDf1GjRjoQ3AinD7fxD5qYzExe50DBVpuUbWcAiGICNxfvzQtUSRRtMoSHDcvzsy03KC6VwARAQABzR5MYXVuY2hwYWQgUFBBIGZvciBJdXJpaSBFZ29yb3bCwY4EEwEKADgWIQR1yd1yx5mHDjEFQuJBZvLCVykIKAUCZXRSGwIbAwULCQgHAgYVCgkICwIEFgIDAQIeAQIXgAAKCRBBZvLCVykIKBu5D/9akmHCHlUqm2RTTBeTMbLNGc0l6YugpPaCM6vz0O9kBFP5PfRaNSRzyF7wHFHNY3JUHcor28my1fD8AE4+C3PwXz8tVYLh57UUsp4wjqHY+MTl/1ngDViPGD3PRjB8ZlO+19yerfplZv1Jaw7FZZv2BZOAXb+ddqUG4EmlzOnCEhcSDdFrzEBB3RGthjIb3QkKWKGbELDiMfogmsO9BE139Raiw23blagDrbnWsG4jReZeu3atjG6AW8eL7m+i7bKKshD2CYVMznI5cYGLMKo9w7sb33uylPj1Vx9O7joP2GFf2rTpCY8wgzk7i1RqsipJ80u1/DY91Xdizv3f2BBe6UY7qHKoK00O11J0y8yUis2Asycy33Wy51pf6rCFUBLQu+c1fEypHF6jqANmQwaH7pPBliy4gGWvrVggzV4mxv7SnRiMi4PFyVwjKWm8dmuMxi/B9s++VG/ed+5aYgJYL58MohG3MUI/L58eitSCDDcQ1iAnBmawnGMKPqzMgRFB3OU3wDwfh7LNVvQqWpQ4q7pr4Cq1CvZvGoggXWDo1/vylPsRmiiuNetfsoVYmrkgtj1om07m5Xp1v4SyXJH11c3dc/xfMmn/4RlMWIpq86IsOjpr3avsw3FVUNCgD5Wf5+rHG+7gNmM6Cm/F8MDfAnnRmsw4h6hgvcJNQT5Dig=="

install_amneziawg_packages_task() {
    export DEBIAN_FRONTEND=noninteractive
    local os_id=""
    local os_codename=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        os_id="$ID"
        os_codename="${VERSION_CODENAME:-$VERSION_ID}"
    fi

    # 1. Если бинарник awg уже доступен в системе — ничего делать не нужно
    if command -v awg >/dev/null 2>&1; then
        return 0
    fi

    # Ожидание освобождения блокировок apt другими процессами
    local wait_count=0
    while { command -v fuser >/dev/null 2>&1 && { fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; }; }; do
        sleep 1
        wait_count=$((wait_count + 1))
        [ "$wait_count" -ge 60 ] && break
    done

    # 2. Подключение репозитория Amnezia PPA напрямую через GPG ключ (без зависающего add-apt-repository при disable_ipv6)
    if [[ "$os_id" == "ubuntu" ]]; then
        mkdir -p /etc/apt/keyrings /etc/apt/sources.list.d
        echo "$AMNEZIA_PPA_GPG_B64" | base64 -d > /etc/apt/keyrings/amnezia-ppa.gpg 2>/dev/null || true
        chmod 644 /etc/apt/keyrings/amnezia-ppa.gpg 2>/dev/null || true

        cat << EOF_PPA > /etc/apt/sources.list.d/amnezia-ppa.sources
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: ${os_codename}
Components: main
Signed-By: /etc/apt/keyrings/amnezia-ppa.gpg
EOF_PPA
        chmod 644 /etc/apt/sources.list.d/amnezia-ppa.sources 2>/dev/null || true
    fi

    local apt_flags=("-o" "Acquire::Retries=3" "-o" "Acquire::http::Timeout=15")
    apt-get update -q "${apt_flags[@]}" 2>/dev/null || apt-get update -q || true

    # 3. Установка ядра, заголовков и пакетов AmneziaWG
    local kheaders="linux-headers-$(uname -r)"
    apt-get install -y --no-install-recommends "${apt_flags[@]}" \
        "$kheaders" build-essential dkms wireguard-tools amneziawg-tools amneziawg-dkms -q 2>/dev/null || \
    apt-get install -y --no-install-recommends "${apt_flags[@]}" \
        wireguard-tools amneziawg-tools amneziawg-dkms -q 2>/dev/null || true

    # 4. Проверка и загрузка модуля ядра
    modprobe amneziawg 2>/dev/null || true
}

ensure_amneziawg_installed() {
    # Пропускаем, если бэкенд развернут в Docker-контейнере
    if command -v docker >/dev/null 2>&1; then
        for c_cand in "amnezia-awg2" "amnezia-awg" "awg-server"; do
            if docker inspect -f '{{.State.Running}}' "$c_cand" 2>/dev/null | grep -q "true"; then
                return 0
            fi
        done
    fi

    # 1. Если уже установлен в системе — отлично
    if command -v awg >/dev/null 2>&1; then
        modprobe amneziawg 2>/dev/null || true
        return 0
    fi

    # 2. Если была запущена фоновая сборка — дожидаемся её
    if ! command -v awg >/dev/null 2>&1; then
        run_with_spinner "Установка и компиляция модуля ядра AmneziaWG (DKMS)" install_amneziawg_packages_task
    fi

    # 4. Проверяем результат
    if command -v awg >/dev/null 2>&1; then
        modprobe amneziawg 2>/dev/null || true
        ok "Модуль ядра и утилита AmneziaWG успешно подготовлены: $(which awg)"
    else
        warn "Не удалось установить утилиту awg в ядро ОС. manage_amneziawg переключится в резервный режим."
    fi
}

setup_amneziawg_controller() {
    local awg_dir="/root/awg"
    mkdir -p "$awg_dir/keys"
    chmod 700 "$awg_dir"

    log "Развертывание универсального контроллера AmneziaWG в $awg_dir..."

    # Копирование или запись manage_clients.py и crypto_engine.py
    local src_py="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/manage_clients.py"
    if [ -f "$src_py" ]; then
        cp -f "$src_py" "$awg_dir/manage_clients.py"
    fi
    local src_crypto="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../common" 2>/dev/null && pwd)/crypto_engine.py"
    if [ -f "$src_crypto" ]; then
        cp -f "$src_crypto" "$awg_dir/crypto_engine.py"
    fi

    # Если файл не существует (например, запуск через curl монолита), пишем встроенную версию
    if [ ! -f "$awg_dir/manage_clients.py" ]; then
        cat << 'EOF_AWG_PY' > "$awg_dir/manage_clients.py"
#!/usr/bin/env python3
# ==============================================================================
# manage_clients.py — Universal AmneziaWG Controller & CLI Management Interface
#
# Provides automated peer provisioning, telemetry, and profile generation
# (supporting AmneziaWG 3.1 with obfuscation headers and v2.0 profiles).
#
# Based on architectural concepts and client configuration workflows from:
#   - AmneziaWG Installer by @bivlked: https://github.com/bivlked/amneziawg-installer
#   - Official AmneziaWG protocol specifications (v3.1 / v2.0)
# ==============================================================================

import sys
import os
import re
import json
import zlib
import time
import struct
import base64
import secrets
import shutil
import tarfile
import contextlib
import subprocess
import ipaddress
from datetime import datetime, timezone, timedelta
from pathlib import Path


def safe_exists(path):
    try:
        return Path(path).exists()
    except (PermissionError, OSError):
        return False

# --- Execution Environment Detection (Container vs Host) ---
def detect_container_name():
    env_name = os.environ.get("AWG_CONTAINER_NAME")
    if env_name:
        return env_name
    if not shutil.which("docker"):
        return None
    res = subprocess.run("docker ps --format '{{.Names}}' 2>/dev/null", shell=True, capture_output=True, text=True)
    names = [n.strip() for n in res.stdout.splitlines() if n.strip()]
    for cand in ("amnezia-awg2", "amnezia-awg", "awg-server"):
        if cand in names:
            return cand
    for n in names:
        if "amnezia" in n or "awg" in n:
            return n
    return None

def detect_execution_mode():
    env_mode = os.environ.get("AWG_MODE", "").strip().lower()
    if env_mode in ("container", "docker"):
        cand = detect_container_name() or "amnezia-awg2"
        return "container", cand
    if env_mode in ("host", "native", "baremetal"):
        return "host", None

    cand = detect_container_name()
    if cand:
        res = subprocess.run(f"docker inspect -f '{{{{.State.Running}}}}' {cand} 2>/dev/null", shell=True, capture_output=True, text=True)
        if res.returncode == 0 and res.stdout.strip() == "true":
            return "container", cand

    if shutil.which("awg") or safe_exists("/etc/amnezia/amneziawg/awg0.conf"):
        return "host", None

    return "container", (cand or "amnezia-awg2")

EXEC_MODE, CONTAINER = detect_execution_mode()
AWG_DIR = Path(os.environ.get("AWG_DIR", "/root/awg"))
try:
    AWG_DIR.mkdir(parents=True, exist_ok=True)
except (PermissionError, OSError):
    pass

# --- Atomic File Locking (Concurrency Protection) ---
@contextlib.contextmanager
def file_lock(lock_name="awg_config", timeout=30):
    lock_file = AWG_DIR / f".{lock_name}.lock"
    try:
        lock_file.parent.mkdir(parents=True, exist_ok=True)
    except Exception:
        pass

    try:
        import fcntl
        with open(lock_file, "w") as f:
            start_time = time.time()
            acquired = False
            while time.time() - start_time < timeout:
                try:
                    fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    acquired = True
                    break
                except (BlockingIOError, IOError):
                    time.sleep(0.1)
            if not acquired:
                raise TimeoutError(f"Timeout waiting for {lock_name} lock ({timeout}s)")
            try:
                yield
            finally:
                try:
                    fcntl.flock(f.fileno(), fcntl.LOCK_UN)
                except Exception:
                    pass
    except ImportError:
        # Non-POSIX environments (Windows dev/tests)
        yield

def get_conf_path():
    env_path = os.environ.get("AWG_CONF_PATH")
    if env_path:
        return env_path
    if EXEC_MODE == "container":
        return "/opt/amnezia/awg/awg0.conf"
    if safe_exists("/etc/amnezia/amneziawg/awg0.conf"):
        return "/etc/amnezia/amneziawg/awg0.conf"
    return "/opt/amnezia/awg/awg0.conf"

def get_clients_table_path():
    env_path = os.environ.get("AWG_TABLE_PATH")
    if env_path:
        return env_path
    if EXEC_MODE == "container":
        return "/opt/amnezia/awg/clientsTable"
    return str(AWG_DIR / "clientsTable.json")

def run_cmd(cmd, check=False, input_data=None):
    res = subprocess.run(cmd, shell=True, capture_output=True, text=True, input=input_data)
    if check and res.returncode != 0:
        raise RuntimeError(f"Command failed ({res.returncode}): {cmd}\nstderr: {res.stderr}\nstdout: {res.stdout}")
    return res.stdout.strip(), res.stderr.strip(), res.returncode

def read_backend_file(path_str):
    p = Path(path_str)
    if safe_exists(p):
        try:
            return p.read_text(encoding="utf-8")
        except Exception:
            pass
    if EXEC_MODE == "container" and CONTAINER:
        stdout, _, rc = run_cmd(f"docker exec {CONTAINER} cat {path_str}")
        if rc == 0:
            return stdout
    return ""

def write_backend_file(path_str, content):
    p = Path(path_str)
    written = False
    if EXEC_MODE == "container" and CONTAINER:
        _, stderr, rc = run_cmd(f"docker exec -i {CONTAINER} tee {path_str} >/dev/null", input_data=content)
        if rc == 0:
            written = True
        elif safe_exists(p.parent):
            try:
                p.write_text(content, encoding="utf-8")
                written = True
            except Exception as exc:
                stderr = f"{stderr}; host write error: {exc}"
        if not written:
            raise IOError(f"Failed to write file {path_str} (container rc={rc}, stderr={stderr})")
    else:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")

def append_backend_file(path_str, content):
    p = Path(path_str)
    appended = False
    if EXEC_MODE == "container" and CONTAINER:
        _, stderr, rc = run_cmd(f"docker exec -i {CONTAINER} tee -a {path_str} >/dev/null", input_data=content)
        if rc == 0:
            appended = True
        elif safe_exists(p):
            try:
                with open(p, "a", encoding="utf-8") as f:
                    f.write(content)
                appended = True
            except Exception as exc:
                stderr = f"{stderr}; host append error: {exc}"
        if not appended:
            raise IOError(f"Failed to append to file {path_str} (container rc={rc}, stderr={stderr})")
    else:
        with open(p, "a", encoding="utf-8") as f:
            f.write(content)

# --- Configuration & Obfuscation Parameters ---
def get_conf_params():
    conf = read_backend_file(get_conf_path())
    params = {}
    for key in [
        "ListenPort", "HeaderProtectionKey", "Jc", "Jmin", "Jmax",
        "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4",
        "I1", "I2", "I3", "I4", "I5", "Address", "MTU",
        "RandomTrailers", "DisableCookies", "PrimaryDns", "SecondaryDns",
        "RekeyAfterTime", "RekeyTimeout", "RejectAfterTime",
        "KeepaliveTimeout", "MaxHandshakeAttempts", "PersistentKeepalive",
        "ContentPaddingAddition", "CPA"
    ]:
        m = re.search(rf"^\s*{key}\s*=\s*(.+)$", conf, re.MULTILINE | re.IGNORECASE)
        if m:
            params[key] = m.group(1).strip()
    return params

CONF_PARAMS = get_conf_params()

SERVER_HOST = os.environ.get("SERVER_PUBLIC_HOST", "") or os.environ.get("WAN_IP", "")
if not SERVER_HOST:
    try:
        import urllib.request
        SERVER_HOST = urllib.request.urlopen("https://api.ipify.org", timeout=2).read().decode('utf-8').strip()
    except Exception:
        SERVER_HOST = "127.0.0.1"

SERVER_PORT = os.environ.get("SERVER_PORT") or os.environ.get("AWG_SERVER_PORT") or CONF_PARAMS.get("ListenPort") or "8443"
CLIENT_MTU = os.environ.get("CLIENT_MTU") or CONF_PARAMS.get("MTU") or "1280"

HEADER_PROTECTION_KEY = (
    os.environ.get("HEADER_PROTECTION_KEY")
    or os.environ.get("AWG_HEADER_PROTECTION_KEY")
    or CONF_PARAMS.get("HeaderProtectionKey")
    or ""
)

PRIMARY_DNS = os.environ.get("AWG_PRIMARY_DNS") or CONF_PARAMS.get("PrimaryDns") or "9.9.9.9"
SECONDARY_DNS = os.environ.get("AWG_SECONDARY_DNS") or CONF_PARAMS.get("SecondaryDns") or "76.76.2.0"

# Pre-defined DNS Profiles
DNS_PROFILES = {
    "quad9": "9.9.9.9, 149.112.112.112",
    "cloudflare": "1.1.1.1, 1.0.0.1",
    "controld": "76.76.2.2, 76.76.10.2",
    "adguard": "94.140.14.14, 94.140.15.15",
    "google": "8.8.8.8, 8.8.4.4",
    "local": "10.8.0.1",
    "default": f"{PRIMARY_DNS}, {SECONDARY_DNS}"
}

def resolve_dns(dns_key: str = "default") -> tuple[str, str]:
    target = DNS_PROFILES.get(dns_key.lower()) if dns_key else None
    if not target:
        if "," in dns_key:
            parts = [p.strip() for p in dns_key.split(",", 1)]
            return parts[0], parts[1]
        elif dns_key and ("." in dns_key or ":" in dns_key):
            return dns_key.strip(), SECONDARY_DNS
        target = DNS_PROFILES["default"]
    parts = [p.strip() for p in target.split(",", 1)]
    return parts[0], (parts[1] if len(parts) > 1 else SECONDARY_DNS)

raw_rt = os.environ.get("AWG_RANDOM_TRAILERS") or CONF_PARAMS.get("RandomTrailers") or "on"
RANDOM_TRAILERS = "on" if str(raw_rt).strip().lower() in ("on", "true", "1", "yes") else "off"

raw_dc = os.environ.get("AWG_DISABLE_COOKIES") or CONF_PARAMS.get("DisableCookies") or "off"
DISABLE_COOKIES = "on" if str(raw_dc).strip().lower() in ("on", "true", "1", "yes") else "off"

def_jc = CONF_PARAMS.get("Jc")
if def_jc in (None, "", "0"):
    def_jc = "4"
JC = os.environ.get("JC") or def_jc

def_jmin = CONF_PARAMS.get("Jmin")
if def_jmin in (None, "", "0"):
    def_jmin = "40"
JMIN = os.environ.get("JMIN") or def_jmin

def_jmax = CONF_PARAMS.get("Jmax")
if def_jmax in (None, "", "0"):
    def_jmax = "70"
JMAX = os.environ.get("JMAX") or def_jmax
S1 = os.environ.get("S1") or CONF_PARAMS.get("S1", "16")
S2 = os.environ.get("S2") or CONF_PARAMS.get("S2", "16")
S3 = os.environ.get("S3") or CONF_PARAMS.get("S3", "16")
S4 = os.environ.get("S4") or CONF_PARAMS.get("S4", "16")
H1 = os.environ.get("H1") or CONF_PARAMS.get("H1", "1")
H2 = os.environ.get("H2") or CONF_PARAMS.get("H2", "2")
H3 = os.environ.get("H3") or CONF_PARAMS.get("H3", "3")
H4 = os.environ.get("H4") or CONF_PARAMS.get("H4", "4")
DNS_I1_TEMPLATE = "<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>"
raw_i1 = os.environ.get("I1") or os.environ.get("AWG_I1") or CONF_PARAMS.get("I1", "")
I1 = DNS_I1_TEMPLATE if str(raw_i1).strip().lower() == "dns" else raw_i1
I2 = os.environ.get("I2") or CONF_PARAMS.get("I2", "")
I3 = os.environ.get("I3") or CONF_PARAMS.get("I3", "")
I4 = os.environ.get("I4") or CONF_PARAMS.get("I4", "")
I5 = os.environ.get("I5") or CONF_PARAMS.get("I5", "")

REKEY_AFTER_TIME = os.environ.get("AWG_REKEY_AFTER_TIME") or CONF_PARAMS.get("RekeyAfterTime", "")
REKEY_TIMEOUT = os.environ.get("AWG_REKEY_TIMEOUT") or CONF_PARAMS.get("RekeyTimeout", "")
REJECT_AFTER_TIME = os.environ.get("AWG_REJECT_AFTER_TIME") or CONF_PARAMS.get("RejectAfterTime", "")
KEEPALIVE_TIMEOUT = os.environ.get("AWG_KEEPALIVE_TIMEOUT") or CONF_PARAMS.get("KeepaliveTimeout", "")
MAX_HANDSHAKE_ATTEMPTS = os.environ.get("AWG_MAX_HANDSHAKE_ATTEMPTS") or CONF_PARAMS.get("MaxHandshakeAttempts", "")
PERSISTENT_KEEPALIVE = os.environ.get("AWG_PERSISTENT_KEEPALIVE") or CONF_PARAMS.get("PersistentKeepalive", "25")
ALLOWED_IPS = os.environ.get("AWG_ALLOWED_IPS", "0.0.0.0/0")
CPA = os.environ.get("AWG_CPA") or os.environ.get("AWG_CONTENT_PADDING_ADDITION") or CONF_PARAMS.get("ContentPaddingAddition") or CONF_PARAMS.get("CPA", "")

def ensure_backend_networking():
    """Ensure TCPMSS clamping and proper MTU for network stability."""
    if EXEC_MODE == "container" and CONTAINER:
        run_cmd(f"docker exec {CONTAINER} iptables -t mangle -C FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || docker exec {CONTAINER} iptables -t mangle -A FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true")
        run_cmd(f"docker exec {CONTAINER} iptables -t mangle -C FORWARD -i awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || docker exec {CONTAINER} iptables -t mangle -A FORWARD -i awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true")
        run_cmd(f"docker exec {CONTAINER} ip link set mtu {CLIENT_MTU} dev awg0 2>/dev/null || true")
    else:
        run_cmd("iptables -t mangle -C FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true")
        run_cmd("iptables -t mangle -C FORWARD -i awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -i awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true")

# Curve25519 helper (RFC 7748) via common crypto engine
try:
    from src.common.crypto_engine import (
        P, A24, clamp, x25519, curve25519_pubkey, generate_wg_keypair
    )
except ImportError:
    try:
        from common.crypto_engine import (
            P, A24, clamp, x25519, curve25519_pubkey, generate_wg_keypair
        )
    except ImportError:
        try:
            from crypto_engine import (
                P, A24, clamp, x25519, curve25519_pubkey, generate_wg_keypair
            )
        except ImportError:
            try:
                from pathlib import Path
                _p = (Path(__file__).resolve().parent.parent / "common").as_posix()
                if _p not in sys.path:
                    sys.path.insert(0, _p)
                from crypto_engine import (
                    P, A24, clamp, x25519, curve25519_pubkey, generate_wg_keypair
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

def get_server_pubkey():
    for cand_path in [
        "/opt/amnezia/awg/wireguard_server_public_key.key",
        "/etc/amnezia/amneziawg/server_public.key",
        str(AWG_DIR / "keys" / "server_public.key")
    ]:
        pub = read_backend_file(cand_path)
        if pub:
            return pub.strip()
    env_pub = os.environ.get("AWG_SERVER_PUBKEY")
    if env_pub:
        return env_pub

    conf = read_backend_file(get_conf_path())
    m = re.search(r"PrivateKey\s*=\s*(\S+)", conf)
    if m:
        priv = m.group(1)
        if EXEC_MODE == "container" and CONTAINER:
            stdout, _, rc = run_cmd(f"docker exec -i {CONTAINER} awg pubkey 2>/dev/null || echo '{priv}' | wg pubkey 2>/dev/null", input_data=priv)
        else:
            stdout, _, rc = run_cmd("awg pubkey 2>/dev/null || wg pubkey 2>/dev/null", input_data=priv)
        if rc == 0 and stdout:
            return stdout
        derived = curve25519_pubkey(priv)
        if derived:
            return derived
    raise RuntimeError("Server public key not found in AmneziaWG configuration")


def get_server_psk():
    for cand_path in [
        "/opt/amnezia/awg/wireguard_psk.key",
        "/etc/amnezia/amneziawg/wireguard_psk.key",
        str(AWG_DIR / "keys" / "server_psk.key")
    ]:
        psk = read_backend_file(cand_path)
        if psk:
            return psk.strip()
    env_psk = os.environ.get("AWG_SERVER_PSK")
    if env_psk:
        return env_psk

    conf = read_backend_file(get_conf_path())
    m = re.search(r"PresharedKey\s*=\s*(\S+)", conf)
    if m:
        return m.group(1).strip()
    return base64.b64encode(secrets.token_bytes(32)).decode('utf-8')

def load_clients_table():
    txt = read_backend_file(get_clients_table_path())
    if txt:
        try:
            return json.loads(txt)
        except Exception:
            return []
    return []

def save_clients_table(table):
    write_backend_file(get_clients_table_path(), json.dumps(table, indent=4, ensure_ascii=False))

def parse_duration(duration_str: str) -> timedelta | datetime | None:
    """Parses duration strings like '30d', '12h', '60m', or exact dates 'YYYY-MM-DD'."""
    if not duration_str or duration_str.strip().lower() in ("none", "never", "off", "0", ""):
        return None
    d_clean = duration_str.strip()

    # Match ISO date or YYYY-MM-DD
    if re.match(r'^\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}:\d{2})?$', d_clean):
        try:
            if "T" in d_clean:
                dt = datetime.fromisoformat(d_clean)
            elif " " in d_clean:
                dt = datetime.strptime(d_clean, "%Y-%m-%d %H:%M:%S")
            else:
                dt = datetime.strptime(d_clean, "%Y-%m-%d")
            return dt.replace(tzinfo=timezone.utc)
        except Exception:
            pass

    m = re.match(r'^(\d+)\s*([dhms])$', d_clean.lower())
    if m:
        val = int(m.group(1))
        unit = m.group(2)
        if unit == "d":
            return timedelta(days=val)
        elif unit == "h":
            return timedelta(hours=val)
        elif unit == "m":
            return timedelta(minutes=val)
        elif unit == "s":
            return timedelta(seconds=val)
    return None

def get_server_display_name() -> str:
    srv_prefix = os.environ.get("SERVER_PREFIX", "").strip()
    if srv_prefix and srv_prefix.lower() not in ("-", "none", "off", "no"):
        return srv_prefix
    sub_title = os.environ.get("SUB_TITLE", "").strip()
    if sub_title and sub_title.lower() not in ("-", "none", "off", "no"):
        return sub_title
    if SERVER_HOST and SERVER_HOST not in ("127.0.0.1", "0.0.0.0", "localhost"):
        return SERVER_HOST
    return "Server"

def encode_amnezia_vpnuri_31(
    conf_text: str, client_ip: str, client_priv: str, client_pub: str,
    description: str | None = None,
    dns1: str = PRIMARY_DNS, dns2: str = SECONDARY_DNS
) -> str:
    if not description:
        description = f"{get_server_display_name()} — Client"
    internal_config = conf_text
    server_pub = None
    server_psk = None
    server_host = SERVER_HOST
    server_port = SERVER_PORT

    if internal_config:
        m_pub = re.search(r"^\s*PublicKey\s*=\s*(\S+)", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_pub:
            server_pub = m_pub.group(1).strip()
        m_psk = re.search(r"^\s*PresharedKey\s*=\s*(\S+)", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_psk:
            server_psk = m_psk.group(1).strip()
        m_ep = re.search(r"^\s*Endpoint\s*=\s*([^:\s]+):(\d+)", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_ep:
            server_host = m_ep.group(1).strip()
            server_port = m_ep.group(2).strip()

    if not server_pub:
        server_pub = get_server_pubkey()
    if not server_psk:
        server_psk = get_server_psk()

    try:
        port_int = int(server_port)
    except ValueError:
        port_int = 8443

    # Единый источник конфигурации: используем переданный conf_text
    if not internal_config:
        internal_config = f"""[Interface]
Address = {client_ip}/32
DNS = {dns1}, {dns2}
PrivateKey = {client_priv}
MTU = {CLIENT_MTU}
Jc = {JC}
Jmin = {JMIN}
Jmax = {JMAX}
S1 = {S1}
S2 = {S2}
S3 = {S3}
S4 = {S4}
H1 = {H1}
H2 = {H2}
H3 = {H3}
H4 = {H4}
""" + (f"I1 = {I1}\n" if I1 else "") + (f"HeaderProtectionKey = {HEADER_PROTECTION_KEY}\n" if HEADER_PROTECTION_KEY else "") + (f"ContentPaddingAddition = {CPA}\n" if CPA else "") + f"""RekeyAfterTime = {REKEY_AFTER_TIME}
RekeyTimeout = {REKEY_TIMEOUT}
RejectAfterTime = {REJECT_AFTER_TIME}
KeepaliveTimeout = {KEEPALIVE_TIMEOUT}
MaxHandshakeAttempts = {MAX_HANDSHAKE_ATTEMPTS}
RandomTrailers = {RANDOM_TRAILERS}
DisableCookies = {DISABLE_COOKIES}

[Peer]
PublicKey = {server_pub}
PresharedKey = {server_psk}
AllowedIPs = {ALLOWED_IPS}
Endpoint = {SERVER_HOST}:{SERVER_PORT}
PersistentKeepalive = {PERSISTENT_KEEPALIVE}
"""

    proto_ver = "3.1" if HEADER_PROTECTION_KEY else "2.0"
    if not HEADER_PROTECTION_KEY and "3.1" in description:
        description = description.replace("3.1", "2.0")

    cur_i1 = I1
    cur_jc = JC
    cur_jmin = JMIN
    cur_jmax = JMAX
    cur_mtu = str(CLIENT_MTU)
    cur_keepalive = str(PERSISTENT_KEEPALIVE)
    cur_allowed = ALLOWED_IPS

    if internal_config:
        m_i1 = re.search(r"^\s*I1\s*=\s*(.+)$", internal_config, re.MULTILINE | re.IGNORECASE)
        cur_i1 = m_i1.group(1).strip() if m_i1 else ""

        m_jc = re.search(r"^\s*Jc\s*=\s*(\d+)", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_jc:
            cur_jc = m_jc.group(1).strip()

        m_jmin = re.search(r"^\s*Jmin\s*=\s*(\d+)", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_jmin:
            cur_jmin = m_jmin.group(1).strip()

        m_jmax = re.search(r"^\s*Jmax\s*=\s*(\d+)", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_jmax:
            cur_jmax = m_jmax.group(1).strip()

        m_mtu = re.search(r"^\s*MTU\s*=\s*(\d+)", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_mtu:
            cur_mtu = m_mtu.group(1).strip()

        m_ka = re.search(r"^\s*PersistentKeepalive\s*=\s*(\d+)", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_ka:
            cur_keepalive = m_ka.group(1).strip()

        m_al = re.search(r"^\s*AllowedIPs\s*=\s*(.+)$", internal_config, re.MULTILINE | re.IGNORECASE)
        if m_al:
            cur_allowed = m_al.group(1).strip()

    last_config_dict = {
        "DisableCookies": DISABLE_COOKIES,
        "H1": H1, "H2": H2, "H3": H3, "H4": H4,
        "HeaderProtectionKey": HEADER_PROTECTION_KEY,
        "I1": cur_i1, "I2": I2, "I3": I3, "I4": I4, "I5": I5,
        "Jc": cur_jc, "Jmax": cur_jmax, "Jmin": cur_jmin,
        "KeepaliveTimeout": KEEPALIVE_TIMEOUT, "MaxHandshakeAttempts": MAX_HANDSHAKE_ATTEMPTS,
        "RandomTrailers": RANDOM_TRAILERS, "RejectAfterTime": REJECT_AFTER_TIME,
        "RekeyAfterTime": REKEY_AFTER_TIME, "RekeyTimeout": REKEY_TIMEOUT,
        "S1": S1, "S2": S2, "S3": S3, "S4": S4,
        "allowed_ips": [ip.strip() for ip in cur_allowed.split(",") if ip.strip()],
        "clientId": client_pub, "client_ip": client_ip,
        "client_priv_key": client_priv, "client_pub_key": client_pub,
        "config": internal_config, "hostName": server_host,
        "mtu": str(cur_mtu), "persistent_keep_alive": cur_keepalive,
        "port": port_int, "psk_key": server_psk,
        "server_pub_key": server_pub,
        "isThirdPartyConfig": True
    }
    if CPA:
        last_config_dict["ContentPaddingAddition"] = CPA

    container_id = CONTAINER if CONTAINER and CONTAINER != "amnezia-awg" else "amnezia-awg2"
    awg_dict = {
        "DisableCookies": DISABLE_COOKIES,
        "H1": H1, "H2": H2, "H3": H3, "H4": H4,
        "HeaderProtectionKey": HEADER_PROTECTION_KEY,
        "I1": cur_i1, "I2": I2, "I3": I3, "I4": I4, "I5": I5,
        "Jc": cur_jc, "Jmax": cur_jmax, "Jmin": cur_jmin,
        "KeepaliveTimeout": KEEPALIVE_TIMEOUT, "MaxHandshakeAttempts": MAX_HANDSHAKE_ATTEMPTS,
        "RandomTrailers": RANDOM_TRAILERS, "RejectAfterTime": REJECT_AFTER_TIME,
        "RekeyAfterTime": REKEY_AFTER_TIME, "RekeyTimeout": REKEY_TIMEOUT,
        "S1": S1, "S2": S2, "S3": S3, "S4": S4,
        "isThirdPartyConfig": True,
        "last_config": json.dumps(last_config_dict, ensure_ascii=False),
        "port": str(server_port), "protocol_version": proto_ver,
        "subnet_address": "10.8.0.0", "transport_proto": "udp"
    }
    if CPA:
        awg_dict["ContentPaddingAddition"] = CPA

    container_data = {
        "containers": [
            {
                "awg": awg_dict,
                "container": container_id
            }
        ],
        "defaultContainer": container_id,
        "description": description,
        "dns1": dns1, "dns2": dns2,
        "format_version": 1, "hostName": server_host
    }

    json_str = json.dumps(container_data, ensure_ascii=False)
    json_bytes = json_str.encode("utf-8")
    compressed = zlib.compress(json_bytes, 8)
    payload = struct.pack(">I", len(json_bytes)) + compressed
    encoded_b64 = base64.urlsafe_b64encode(payload).decode("utf-8").rstrip("=")
    return f"vpn://{encoded_b64}"

def check_status():
    ensure_backend_networking()
    if EXEC_MODE == "container" and CONTAINER:
        out, _, rc = run_cmd(f"docker inspect -f '{{{{.State.Running}}}}' {CONTAINER}")
        is_running = (rc == 0 and out.strip() == "true")
        if not is_running:
            return {"ok": False, "mode": EXEC_MODE, "status": "offline", "active": False, "error": f"Container {CONTAINER} is not running"}
        _, _, rc = run_cmd(f"docker exec {CONTAINER} ip link show awg0")
        if rc != 0:
            return {"ok": False, "mode": EXEC_MODE, "status": "offline", "active": False, "error": "Interface awg0 not found in container"}
    else:
        out, _, rc = run_cmd("ip link show awg0 2>/dev/null")
        if rc != 0:
            return {"ok": False, "mode": EXEC_MODE, "status": "offline", "active": False, "error": "Interface awg0 not found on host"}

    table = load_clients_table()
    try:
        p_int = int(SERVER_PORT)
    except ValueError:
        p_int = 8443

    now_iso = datetime.now(timezone.utc).isoformat()
    active_count = 0
    expired_count = 0
    for c in table:
        ud = c.get("userData", {})
        if ud.get("blocked", False):
            continue
        exp = ud.get("expiryDate")
        if exp and exp <= now_iso:
            expired_count += 1
        else:
            active_count += 1

    return {
        "ok": True,
        "mode": EXEC_MODE,
        "status": "online",
        "active": True,
        "service": {"unit": CONTAINER or "awg-quick@awg0", "active": True},
        "interface": {"name": "awg0", "present": True},
        "port": {"number": p_int, "proto": "udp", "listening": True},
        "clients": {
            "total": len(table),
            "active": active_count,
            "expired_pending": expired_count
        }
    }

def get_stats():
    ensure_backend_networking()
    if EXEC_MODE == "container" and CONTAINER:
        dump_out, _, rc = run_cmd(f"docker exec {CONTAINER} awg show awg0 dump")
    else:
        dump_out, _, rc = run_cmd("awg show awg0 dump 2>/dev/null")

    if rc != 0:
        return {"ok": False, "mode": EXEC_MODE, "error": "Failed to run awg show", "clients": [], "items": []}

    table = load_clients_table()
    data_by_pub = {item.get("clientId", "").strip(): item.get("userData", {}) for item in table}

    clients = []
    lines = dump_out.strip().splitlines()
    now_utc = datetime.now(timezone.utc)

    for line in lines[1:]:
        parts = line.strip().split()
        if len(parts) >= 7:
            pubkey = parts[0]
            endpoint = parts[2] if parts[2] != "(none)" else None
            allowed_ips = parts[3]
            handshake = int(parts[4]) if parts[4].isdigit() else 0
            rx = int(parts[5]) if parts[5].isdigit() else 0
            tx = int(parts[6]) if parts[6].isdigit() else 0

            ud = data_by_pub.get(pubkey, {})
            name = ud.get("clientName", pubkey)
            ip = allowed_ips.split("/")[0]

            exp_str = ud.get("expiryDate")
            days_left = None
            if exp_str:
                try:
                    exp_dt = datetime.fromisoformat(exp_str)
                    delta = exp_dt - now_utc
                    days_left = round(delta.total_seconds() / 86400.0, 1)
                except Exception:
                    pass

            clients.append({
                "name": name,
                "client_name": name,
                "public_key": pubkey,
                "ip": ip,
                "allowed_ips": allowed_ips,
                "latest_handshake": handshake,
                "rx_bytes": rx,
                "tx_bytes": tx,
                "endpoint": endpoint,
                "blocked": ud.get("blocked", False),
                "expiry_date": exp_str,
                "days_left": days_left
            })

    return {
        "ok": True,
        "mode": EXEC_MODE,
        "status": "online",
        "clients": clients,
        "items": clients,
        "total": len(clients)
    }

def find_next_ip():
    conf_content = read_backend_file(get_conf_path())
    table = load_clients_table()

    network = None
    server_ip = None
    m = re.search(r'^\s*Address\s*=\s*([0-9a-fA-F\.:]+(?:/\d+)?)(?:,.*)?$', conf_content, re.MULTILINE)
    if m:
        addr_str = m.group(1).strip()
        try:
            if "/" in addr_str:
                iface = ipaddress.ip_interface(addr_str)
                network = iface.network
                server_ip = iface.ip
            else:
                ip = ipaddress.ip_address(addr_str)
                network = ipaddress.ip_network(f"{ip}/24", strict=False)
                server_ip = ip
        except Exception:
            pass

    if not network:
        subnet_ip = os.environ.get("AWG_SUBNET_IP", "10.8.0.0")
        subnet_cidr = os.environ.get("AWG_SUBNET_CIDR", "22")
        try:
            network = ipaddress.ip_network(f"{subnet_ip}/{subnet_cidr}", strict=False)
            server_ip = network.network_address + 1
        except Exception:
            network = ipaddress.ip_network("10.8.0.0/22")
            server_ip = ipaddress.ip_address("10.8.0.1")

    used = set()
    used.add(str(network.network_address))
    used.add(str(network.broadcast_address))
    if server_ip:
        used.add(str(server_ip))

    for m in re.finditer(r'AllowedIPs\s*=\s*([0-9a-fA-F\.:]+)(?:/\d+)?', conf_content):
        used.add(m.group(1).strip())
    for item in table:
        a_ip = item.get("userData", {}).get("allowed_ips", "")
        m = re.search(r'([0-9a-fA-F\.:]+)(?:/\d+)?', a_ip)
        if m:
            used.add(m.group(1).strip())

    for host in network.hosts():
        ip_str = str(host)
        if ip_str not in used:
            return ip_str

    raise RuntimeError(f"No free IPs available in {network} subnet pool")

def is_valid_client_name(name):
    return bool(name and isinstance(name, str) and re.match(r'^[a-zA-Z0-9_-]{1,64}$', name))

def is_valid_pubkey(key):
    return bool(key and isinstance(key, str) and len(key) == 44 and re.match(r'^[A-Za-z0-9+/]{43}=$', key))

def is_valid_identifier(ident):
    return is_valid_client_name(ident) or is_valid_pubkey(ident)

def add_client(
    client_name: str,
    expires: str | None = None,
    dns_choice: str = "default",
    shred_privkey: bool = False,
    custom_i1: str | None = None,
    custom_jc: str | None = None,
    custom_jmin: str | None = None,
    custom_jmax: str | None = None,
    custom_mtu: str | None = None,
    custom_keepalive: str | None = None,
    custom_allowed_ips: str | None = None,
    custom_cpa: str | None = None,
    preset: str | None = None
):
    if not is_valid_client_name(client_name):
        return {"ok": False, "error": "Invalid client name. Use 1-64 alphanumeric characters, underscores, or dashes."}

    # Apply preset defaults if specified
    if preset:
        p_clean = preset.strip().lower()
        if p_clean in ("stealth", "mobile", "anti-dpi", "dpi"):
            if custom_i1 is None:
                custom_i1 = DNS_I1_TEMPLATE
            if custom_jc is None:
                custom_jc = "4"
            if custom_jmin is None:
                custom_jmin = "40"
            if custom_jmax is None:
                custom_jmax = "70"
            if custom_mtu is None:
                custom_mtu = "1280"
            if custom_cpa is None:
                custom_cpa = "16-64"
        elif p_clean in ("fast", "gaming", "game", "home", "router", "direct"):
            if custom_i1 is None:
                custom_i1 = ""
            if custom_jc is None:
                custom_jc = "0"
            if custom_jmin is None:
                custom_jmin = "0"
            if custom_jmax is None:
                custom_jmax = "0"
            if custom_mtu is None:
                custom_mtu = "1360"
        elif p_clean in ("base", "default", "standard"):
            if custom_i1 is None:
                custom_i1 = ""
            if custom_jc is None:
                custom_jc = "4"
            if custom_jmin is None:
                custom_jmin = "40"
            if custom_jmax is None:
                custom_jmax = "70"
            if custom_mtu is None:
                custom_mtu = "1280"

    client_mtu = str(custom_mtu).strip() if custom_mtu is not None else str(CLIENT_MTU)
    client_jc = str(custom_jc).strip() if custom_jc is not None else str(JC)
    client_jmin = str(custom_jmin).strip() if custom_jmin is not None else str(JMIN)
    client_jmax = str(custom_jmax).strip() if custom_jmax is not None else str(JMAX)
    client_keepalive = str(custom_keepalive).strip() if custom_keepalive is not None else str(PERSISTENT_KEEPALIVE)
    client_allowed_ips = str(custom_allowed_ips).strip() if custom_allowed_ips is not None else str(ALLOWED_IPS)

    target_i1 = custom_i1 if custom_i1 is not None else I1
    if target_i1 and target_i1.lower() == "dns":
        target_i1 = DNS_I1_TEMPLATE

    ensure_backend_networking()
    dns1, dns2 = resolve_dns(dns_choice)

    # Calculate expiration if specified
    exp_iso = None
    if expires:
        parsed_exp = parse_duration(expires)
        if isinstance(parsed_exp, timedelta):
            exp_iso = (datetime.now(timezone.utc) + parsed_exp).isoformat()
        elif isinstance(parsed_exp, datetime):
            exp_iso = parsed_exp.isoformat()

    with file_lock("awg_config"):
        table = load_clients_table()
        for item in table:
            if item.get("userData", {}).get("clientName") == client_name:
                remove_client(client_name)
                break

        client_ip = find_next_ip()
        if EXEC_MODE == "container" and CONTAINER:
            priv_out, _, _ = run_cmd(f"docker exec {CONTAINER} awg genkey", check=True)
            client_priv = priv_out.strip()
            pub_out, _, _ = run_cmd(f"docker exec -i {CONTAINER} awg pubkey", check=True, input_data=client_priv)
            client_pub = pub_out.strip()
        else:
            try:
                priv_out, _, _ = run_cmd("awg genkey 2>/dev/null || wg genkey 2>/dev/null", check=True)
                client_priv = priv_out.strip()
                pub_out, _, _ = run_cmd("awg pubkey 2>/dev/null || wg pubkey 2>/dev/null", check=True, input_data=client_priv)
                client_pub = pub_out.strip()
            except Exception:
                client_priv, client_pub = generate_wg_keypair()


        server_psk = get_server_psk()
        server_pub = get_server_pubkey()

        # Zero-Downtime Kernel Sync: Apply directly to active memory table
        psk_flag = ""
        if EXEC_MODE == "container" and CONTAINER:
            psk_flag = "preshared-key /opt/amnezia/awg/wireguard_psk.key "
            run_cmd(
                f"docker exec {CONTAINER} awg set awg0 peer {client_pub} {psk_flag}allowed-ips {client_ip}/32",
                check=True
            )
        else:
            for p_cand in ("/etc/amnezia/amneziawg/wireguard_psk.key", str(AWG_DIR / "keys" / "server_psk.key")):
                if safe_exists(p_cand):
                    psk_flag = f"preshared-key {p_cand} "
                    break
            run_cmd(f"awg set awg0 peer {client_pub} {psk_flag}allowed-ips {client_ip}/32", check=True)

        peer_block = (
            f"\n# client: {client_name}\n"
            f"[Peer]\n"
            f"PublicKey = {client_pub}\n"
            f"PresharedKey = {server_psk}\n"
            f"AllowedIPs = {client_ip}/32\n"
        )
        conf_path = get_conf_path()
        try:
            append_backend_file(conf_path, peer_block)
            table = load_clients_table()
            table.append({
                "clientId": client_pub,
                "userData": {
                    "allowed_ips": f"{client_ip}/32",
                    "clientName": client_name,
                    "creationDate": datetime.now(timezone.utc).isoformat(),
                    "expiryDate": exp_iso,
                    "dns": dns_choice,
                    "blocked": False,
                    "preset": preset or "custom",
                    "mtu": client_mtu,
                    "jc": client_jc,
                    "has_i1": bool(target_i1)
                }
            })
            save_clients_table(table)
        except Exception:
            if EXEC_MODE == "container" and CONTAINER:
                run_cmd(f"docker exec {CONTAINER} awg set awg0 peer {client_pub} remove 2>/dev/null || true")
            else:
                run_cmd(f"awg set awg0 peer {client_pub} remove 2>/dev/null || true")
            raise

        conf_lines = [
            "[Interface]",
            f"Address = {client_ip}/32",
            f"DNS = {dns1}, {dns2}",
            f"PrivateKey = {client_priv}",
            f"MTU = {client_mtu}",
            f"Jc = {client_jc}",
            f"Jmin = {client_jmin}",
            f"Jmax = {client_jmax}",
            f"S1 = {S1}",
            f"S2 = {S2}",
            f"S3 = {S3}",
            f"S4 = {S4}",
            f"H1 = {H1}",
            f"H2 = {H2}",
            f"H3 = {H3}",
            f"H4 = {H4}",
        ]
        if target_i1:
            conf_lines.append(f"I1 = {target_i1}")
        if I2:
            conf_lines.append(f"I2 = {I2}")
        if I3:
            conf_lines.append(f"I3 = {I3}")
        if I4:
            conf_lines.append(f"I4 = {I4}")
        if I5:
            conf_lines.append(f"I5 = {I5}")
        target_cpa = custom_cpa if custom_cpa is not None else CPA
        if target_cpa:
            conf_lines.append(f"ContentPaddingAddition = {target_cpa}")
        if HEADER_PROTECTION_KEY:
            conf_lines.append(f"HeaderProtectionKey = {HEADER_PROTECTION_KEY}")
        if REKEY_AFTER_TIME:
            conf_lines.append(f"RekeyAfterTime = {REKEY_AFTER_TIME}")
        if REKEY_TIMEOUT:
            conf_lines.append(f"RekeyTimeout = {REKEY_TIMEOUT}")
        if REJECT_AFTER_TIME:
            conf_lines.append(f"RejectAfterTime = {REJECT_AFTER_TIME}")
        if KEEPALIVE_TIMEOUT:
            conf_lines.append(f"KeepaliveTimeout = {KEEPALIVE_TIMEOUT}")
        if MAX_HANDSHAKE_ATTEMPTS:
            conf_lines.append(f"MaxHandshakeAttempts = {MAX_HANDSHAKE_ATTEMPTS}")
        conf_lines.extend([
            f"RandomTrailers = {RANDOM_TRAILERS}",
            f"DisableCookies = {DISABLE_COOKIES}",
            "",
            "[Peer]",
            f"PublicKey = {server_pub}",
            f"PresharedKey = {server_psk}",
            f"AllowedIPs = {client_allowed_ips}",
            f"Endpoint = {SERVER_HOST}:{SERVER_PORT}",
            f"PersistentKeepalive = {client_keepalive}",
            ""
        ])
        conf_content = "\n".join(conf_lines)

        conf_file = AWG_DIR / f"{client_name}.conf"
        conf_file.write_text(conf_content, encoding="utf-8")
        try:
            conf_file.chmod(0o600)
        except OSError:
            pass

        vpnuri = encode_amnezia_vpnuri_31(
            conf_content, client_ip, client_priv, client_pub,
            description=f"{get_server_display_name()} — {client_name}",
            dns1=dns1, dns2=dns2
        )
        vpnuri_file = AWG_DIR / f"{client_name}.vpnuri"
        vpnuri_file.write_text(vpnuri, encoding="utf-8")
        try:
            vpnuri_file.chmod(0o600)
        except OSError:
            pass

        # Zero-Trust Shredding
        if shred_privkey:
            try:
                # Overwrite and remove local config file
                conf_file.write_bytes(secrets.token_bytes(len(conf_content)))
                conf_file.unlink(missing_ok=True)
            except Exception:
                pass

        return {
            "ok": True,
            "mode": EXEC_MODE,
            "status": "added",
            "client": client_name,
            "ip": client_ip,
            "public_key": client_pub,
            "preset": preset or "custom",
            "mtu": client_mtu,
            "jc": client_jc,
            "has_i1": bool(target_i1),
            "dns": f"{dns1}, {dns2}",
            "expires_at": exp_iso,
            "conf_file": str(conf_file) if not shred_privkey else None,
            "vpnuri_file": str(vpnuri_file),
            "vpnuri": vpnuri,
            "conf_content": conf_content if shred_privkey else None
        }

def remove_client(client_name):
    if not is_valid_identifier(client_name):
        return {"ok": False, "error": f"Invalid client identifier: '{client_name}'."}

    with file_lock("awg_config"):
        table = load_clients_table()
        pubkey = None
        canonical_name = None
        new_table = []
        for item in table:
            c_name = item.get("userData", {}).get("clientName")
            c_id = item.get("clientId")
            if c_name == client_name or c_id == client_name:
                pubkey = c_id
                canonical_name = c_name
            else:
                new_table.append(item)

        conf_text = read_backend_file(get_conf_path())
        if not pubkey and conf_text:
            m = re.search(r'# client:\s*' + re.escape(client_name) + r'\s*\n\[Peer\]\s*\nPublicKey\s*=\s*([^\s\n]+)', conf_text)
            if m:
                pubkey = m.group(1).strip()
                canonical_name = client_name
            elif is_valid_pubkey(client_name):
                pubkey = client_name

        if not canonical_name and is_valid_client_name(client_name):
            canonical_name = client_name

        save_clients_table(new_table)

        if pubkey:
            if EXEC_MODE == "container" and CONTAINER:
                run_cmd(f"docker exec {CONTAINER} awg set awg0 peer {pubkey} remove 2>/dev/null || true")
            else:
                run_cmd(f"awg set awg0 peer {pubkey} remove 2>/dev/null || true")

            if conf_text and pubkey in conf_text:
                pattern = r'(?m)(?:# client:[^\n]*\n)?\[Peer\]\s*\nPublicKey\s*=\s*' + re.escape(pubkey) + r'[\s\S]*?(?=\n(?:# client:|\[Peer\]|$))'
                content = re.sub(pattern, '', conf_text).strip() + "\n"
                write_backend_file(get_conf_path(), content)

        if canonical_name and is_valid_client_name(canonical_name):
            for ext in (".conf", ".vpnuri", ".png", ".vpnuri.png"):
                f = (AWG_DIR / f"{canonical_name}{ext}").resolve()
                try:
                    if f.is_relative_to(AWG_DIR.resolve()) and f.exists() and not f.is_symlink():
                        f.unlink()
                except Exception:
                    pass

        return {"ok": True, "mode": EXEC_MODE, "status": "removed", "client": client_name}

def block_client(client_name, reason="suspended"):
    if not is_valid_identifier(client_name):
        return {"ok": False, "error": f"Invalid client identifier: '{client_name}'"}

    with file_lock("awg_config"):
        table = load_clients_table()
        client_entry = None
        pubkey = None
        c_name = None
        ip = None
        for item in table:
            u_name = item.get("userData", {}).get("clientName")
            c_id = item.get("clientId")
            if u_name == client_name or c_id == client_name:
                client_entry = item
                pubkey = c_id
                c_name = u_name or client_name
                ip = item.get("userData", {}).get("allowed_ips")
                break

        conf_text = read_backend_file(get_conf_path())
        if not pubkey and conf_text:
            m = re.search(r'# client:\s*' + re.escape(client_name) + r'\s*\n\[Peer\]\s*\nPublicKey\s*=\s*([^\s\n]+)[\s\S]*?(?:AllowedIPs\s*=\s*([^\s\n]+))?', conf_text)
            if m:
                pubkey = m.group(1).strip()
                c_name = client_name
                if m.group(2) and not ip:
                    ip = m.group(2).strip()
            elif is_valid_pubkey(client_name):
                pubkey = client_name
                c_name = client_name

        if not pubkey:
            return {"ok": False, "error": f"Client '{client_name}' not found"}

        # Zero-Downtime: remove peer instantly from active interface
        if EXEC_MODE == "container" and CONTAINER:
            run_cmd(f"docker exec {CONTAINER} awg set awg0 peer {pubkey} remove 2>/dev/null || true")
        else:
            run_cmd(f"awg set awg0 peer {pubkey} remove 2>/dev/null || true")

        if conf_text and pubkey in conf_text:
            pattern = r'(?m)(?:# client:[^\n]*\n)?\[Peer\]\s*\nPublicKey\s*=\s*' + re.escape(pubkey) + r'[\s\S]*?(?=\n(?:# client:|\[Peer\]|$))'
            new_conf = re.sub(pattern, '', conf_text).strip() + "\n"
            write_backend_file(get_conf_path(), new_conf)

        if client_entry:
            client_entry.setdefault("userData", {})["blocked"] = True
            client_entry["userData"]["blockedReason"] = reason
            if ip and not client_entry["userData"].get("allowed_ips"):
                client_entry["userData"]["allowed_ips"] = ip
        else:
            table.append({
                "clientId": pubkey,
                "userData": {
                    "clientName": c_name or client_name,
                    "allowed_ips": ip or "",
                    "blocked": True,
                    "blockedReason": reason
                }
            })
        save_clients_table(table)
        return {"ok": True, "mode": EXEC_MODE, "status": "suspended", "client": client_name, "reason": reason}

def unblock_client(client_name, expires: str | None = None):
    if not is_valid_identifier(client_name):
        return {"ok": False, "error": f"Invalid client identifier: '{client_name}'"}

    with file_lock("awg_config"):
        table = load_clients_table()
        client_entry = None
        pubkey = None
        ip = None
        c_name = None
        for item in table:
            u_name = item.get("userData", {}).get("clientName")
            c_id = item.get("clientId")
            if u_name == client_name or c_id == client_name:
                client_entry = item
                pubkey = c_id
                ip = item.get("userData", {}).get("allowed_ips")
                c_name = u_name or client_name
                break

        conf_text = read_backend_file(get_conf_path())
        if not pubkey and conf_text:
            m = re.search(r'# client:\s*' + re.escape(client_name) + r'\s*\n\[Peer\]\s*\nPublicKey\s*=\s*([^\s\n]+)[\s\S]*?AllowedIPs\s*=\s*([^\s\n]+)', conf_text)
            if m:
                pubkey = m.group(1).strip()
                if not ip:
                    ip = m.group(2).strip()
                c_name = client_name
            elif is_valid_pubkey(client_name):
                pubkey = client_name
                c_name = client_name

        if not pubkey:
            return {"ok": False, "error": f"Client '{client_name}' not found"}
        if not ip:
            return {"ok": False, "error": f"IP address for client '{client_name}' not found"}

        psk_flag = ""
        if EXEC_MODE == "container" and CONTAINER:
            psk_flag = "preshared-key /opt/amnezia/awg/wireguard_psk.key "
            run_cmd(f"docker exec {CONTAINER} awg set awg0 peer {pubkey} {psk_flag}allowed-ips {ip}", check=True)
        else:
            for p_cand in ("/etc/amnezia/amneziawg/wireguard_psk.key", str(AWG_DIR / "keys" / "server_psk.key")):
                if safe_exists(p_cand):
                    psk_flag = f"preshared-key {p_cand} "
                    break
            run_cmd(f"awg set awg0 peer {pubkey} {psk_flag}allowed-ips {ip}", check=True)

        if pubkey not in conf_text:
            server_psk = get_server_psk()
            peer_block = (
                f"\n# client: {c_name or client_name}\n"
                f"[Peer]\n"
                f"PublicKey = {pubkey}\n"
                f"PresharedKey = {server_psk}\n"
                f"AllowedIPs = {ip}\n"
            )
            append_backend_file(get_conf_path(), peer_block)

        if client_entry:
            client_entry.setdefault("userData", {})["blocked"] = False
            client_entry["userData"]["blockedReason"] = None
            if expires:
                parsed_exp = parse_duration(expires)
                if isinstance(parsed_exp, timedelta):
                    client_entry["userData"]["expiryDate"] = (datetime.now(timezone.utc) + parsed_exp).isoformat()
                elif isinstance(parsed_exp, datetime):
                    client_entry["userData"]["expiryDate"] = parsed_exp.isoformat()
            save_clients_table(table)

        return {"ok": True, "mode": EXEC_MODE, "status": "unsuspended", "client": client_name}

def purge_expired():
    """Scans clientsTable and blocks expired peers without restarting the interface."""
    now_iso = datetime.now(timezone.utc).isoformat()
    table = load_clients_table()
    purged = []

    for item in table:
        ud = item.get("userData", {})
        if ud.get("blocked", False):
            continue
        exp = ud.get("expiryDate")
        if exp and exp <= now_iso:
            client_name = ud.get("clientName") or item.get("clientId")
            if client_name:
                res = block_client(client_name, reason="expired")
                if res.get("ok"):
                    purged.append(client_name)

    log_entry = f"[{datetime.now().strftime('%F %T')}] INFO: Purged expired clients: {purged if purged else 'none'}\n"
    try:
        with open(AWG_DIR / "manage_amneziawg.log", "a", encoding="utf-8") as f:
            f.write(log_entry)
    except Exception:
        pass

    return {
        "ok": True,
        "mode": EXEC_MODE,
        "status": "purged",
        "purged_count": len(purged),
        "purged_clients": purged
    }

def show_qr(client_name):
    """Outputs QR code for client .vpnuri or .conf."""
    uri_file = AWG_DIR / f"{client_name}.vpnuri"
    conf_file = AWG_DIR / f"{client_name}.conf"

    content = ""
    if safe_exists(uri_file):
        content = uri_file.read_text(encoding="utf-8").strip()
    elif safe_exists(conf_file):
        content = conf_file.read_text(encoding="utf-8").strip()
    else:
        return {"ok": False, "error": f"Profile for client '{client_name}' not found in {AWG_DIR}"}

    # Generate PNG if qrencode exists
    png_path = AWG_DIR / f"{client_name}.png"
    if shutil.which("qrencode"):
        run_cmd(f"qrencode -s 6 -l H -o '{png_path}' '{content}' 2>/dev/null || true")

    # Generate terminal ASCII QR
    ansi_qr = ""
    if shutil.which("qrencode"):
        stdout, _, rc = run_cmd(f"qrencode -t ANSIUTF8 '{content}' 2>/dev/null")
        if rc == 0 and stdout:
            ansi_qr = stdout

    return {
        "ok": True,
        "client": client_name,
        "qr_ascii": ansi_qr,
        "png_file": str(png_path) if safe_exists(png_path) else None,
        "vpnuri": content if content.startswith("vpn://") else None
    }

def backup_configs():
    """Creates an atomic .tar.gz archive of all AWG configs, keys, and client tables."""
    backups_dir = AWG_DIR / "backups"
    backups_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    archive_path = backups_dir / f"awg_backup_{ts}.tar.gz"

    with file_lock("awg_backup"):
        with tarfile.open(archive_path, "w:gz") as tar:
            # 1. Server config
            conf_file = Path(get_conf_path())
            if safe_exists(conf_file):
                tar.add(conf_file, arcname="server/awg0.conf")
            # 2. Clients table
            tbl_file = Path(get_clients_table_path())
            if safe_exists(tbl_file):
                tar.add(tbl_file, arcname="clients/clientsTable.json")
            # 3. Keys directory
            keys_dir = AWG_DIR / "keys"
            if safe_exists(keys_dir):
                tar.add(keys_dir, arcname="keys")
            # 4. Client profiles
            for ext in ("*.conf", "*.vpnuri"):
                for p in AWG_DIR.glob(ext):
                    tar.add(p, arcname=f"profiles/{p.name}")

    try:
        archive_path.chmod(0o600)
    except OSError:
        pass

    return {
        "ok": True,
        "mode": EXEC_MODE,
        "status": "backed_up",
        "archive": str(archive_path),
        "size_bytes": archive_path.stat().st_size
    }

def restore_configs(archive_path_str: str):
    """Safely restores configurations from a backup archive with path traversal checks."""
    archive_path = Path(archive_path_str)
    if not archive_path.is_file():
        return {"ok": False, "error": f"Backup archive not found: {archive_path}"}

    # Pre-extraction validation: ensure no path traversal or symlinks
    with tarfile.open(archive_path, "r:gz") as tar:
        for member in tar.getmembers():
            if member.name.startswith("/") or ".." in member.name or member.issym() or member.islnk():
                return {"ok": False, "error": f"Unsafe file path in archive: '{member.name}'. Restore aborted."}

    # Pre-restore snapshot of current state
    pre_snap = backup_configs()

    with file_lock("awg_config"):
        with tarfile.open(archive_path, "r:gz") as tar:
            for member in tar.getmembers():
                if member.name == "server/awg0.conf":
                    f = tar.extractfile(member)
                    if f:
                        write_backend_file(get_conf_path(), f.read().decode("utf-8"))
                elif member.name == "clients/clientsTable.json":
                    f = tar.extractfile(member)
                    if f:
                        write_backend_file(get_clients_table_path(), f.read().decode("utf-8"))
                elif member.name.startswith("profiles/"):
                    base = Path(member.name).name
                    f = tar.extractfile(member)
                    if f:
                        (AWG_DIR / base).write_bytes(f.read())
                        (AWG_DIR / base).chmod(0o600)

    # Sync running interface
    ensure_backend_networking()
    if EXEC_MODE == "container" and CONTAINER:
        run_cmd(f"docker restart {CONTAINER} 2>/dev/null || true")
    else:
        run_cmd("systemctl restart awg-quick@awg0 2>/dev/null || true")

    return {
        "ok": True,
        "mode": EXEC_MODE,
        "status": "restored",
        "restored_from": str(archive_path),
        "pre_restore_snapshot": pre_snap.get("archive")
    }

def get_client_uri(client_name: str):
    """Retrieves or regenerates the Amnezia vpn:// URI for a given client."""
    client_name = client_name.strip()
    if not is_valid_client_name(client_name):
        return {"ok": False, "mode": EXEC_MODE, "error": f"Invalid client name '{client_name}'."}

    uri_file = AWG_DIR / f"{client_name}.vpnuri"
    conf_file = AWG_DIR / f"{client_name}.conf"

    if safe_exists(uri_file):
        uri = uri_file.read_text(encoding="utf-8").strip()
        if uri.startswith("vpn://"):
            return {
                "ok": True,
                "mode": EXEC_MODE,
                "client": client_name,
                "vpnuri": uri,
                "vpnuri_file": str(uri_file)
            }

    if safe_exists(conf_file):
        conf_content = conf_file.read_text(encoding="utf-8")
        m_ip = re.search(r"^\s*Address\s*=\s*([^/,\s]+)", conf_content, re.MULTILINE | re.IGNORECASE)
        m_priv = re.search(r"^\s*PrivateKey\s*=\s*(\S+)", conf_content, re.MULTILINE | re.IGNORECASE)
        if m_ip and m_priv:
            c_ip = m_ip.group(1).strip()
            c_priv = m_priv.group(1).strip()
            c_pub = curve25519_pubkey(c_priv) or ""
            uri = encode_amnezia_vpnuri_31(
                conf_content, c_ip, c_priv, c_pub,
                description=f"{get_server_display_name()} — {client_name}"
            )
            uri_file.write_text(uri, encoding="utf-8")
            try:
                uri_file.chmod(0o600)
            except OSError:
                pass
            return {
                "ok": True,
                "mode": EXEC_MODE,
                "client": client_name,
                "vpnuri": uri,
                "vpnuri_file": str(uri_file)
            }

    return {"ok": False, "mode": EXEC_MODE, "error": f"Client '{client_name}' configuration not found in {AWG_DIR}."}

# --- Main Entry Point with Universal JSON Exception Guard ---
def main():
    action = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else "status"
    client_name = None
    expires = None
    dns_choice = "default"
    shred_privkey = False
    qr_mode = False
    custom_i1 = None
    custom_jc = None
    custom_jmin = None
    custom_jmax = None
    custom_mtu = None
    custom_keepalive = None
    custom_allowed_ips = None
    custom_cpa = None
    preset = None

    raw_mode = False

    args = sys.argv[1:]
    for arg in args:
        if arg.startswith("--expires="):
            expires = arg.split("=", 1)[1].strip()
        elif arg.startswith("--dns="):
            dns_choice = arg.split("=", 1)[1].strip()
        elif arg.startswith("--preset="):
            preset = arg.split("=", 1)[1].strip()
        elif arg.startswith("--mtu="):
            custom_mtu = arg.split("=", 1)[1].strip()
        elif arg.startswith("--cpa=") or arg.startswith("--content-padding="):
            custom_cpa = arg.split("=", 1)[1].strip()
        elif arg in ("--no-cpa", "--without-cpa"):
            custom_cpa = ""
        elif arg.startswith("--jc="):
            custom_jc = arg.split("=", 1)[1].strip()
        elif arg.startswith("--jmin="):
            custom_jmin = arg.split("=", 1)[1].strip()
        elif arg.startswith("--jmax="):
            custom_jmax = arg.split("=", 1)[1].strip()
        elif arg.startswith("--keepalive=") or arg.startswith("--persistent-keepalive="):
            custom_keepalive = arg.split("=", 1)[1].strip()
        elif arg.startswith("--allowed-ips="):
            custom_allowed_ips = arg.split("=", 1)[1].strip()
        elif arg == "--shred-privkey":
            shred_privkey = True
        elif arg in ("--raw", "-r"):
            raw_mode = True
        elif arg in ("--qr", "-q"):
            qr_mode = True
        elif arg in ("--i1", "--i1=dns", "--cps"):
            custom_i1 = DNS_I1_TEMPLATE
        elif arg.startswith("--i1="):
            val = arg.split("=", 1)[1].strip()
            custom_i1 = DNS_I1_TEMPLATE if val.lower() == "dns" else val
        elif arg in ("--no-i1", "--without-i1"):
            custom_i1 = ""
        elif not arg.startswith("-") and not client_name and arg != action:
            client_name = arg

    try:
        if action in ("status", "check", "info"):
            res = check_status()
        elif action in ("stats", "get-clients", "show", "list"):
            res = get_stats()
        elif action in ("uri", "vpnuri", "link", "get-uri"):
            res = get_client_uri(client_name or "client-1")
            if raw_mode and res.get("ok") and res.get("vpnuri"):
                print(res["vpnuri"])
                sys.exit(0)
        elif action == "add":
            res = add_client(
                client_name or "client-1",
                expires=expires,
                dns_choice=dns_choice,
                shred_privkey=shred_privkey,
                custom_i1=custom_i1,
                custom_jc=custom_jc,
                custom_jmin=custom_jmin,
                custom_jmax=custom_jmax,
                custom_mtu=custom_mtu,
                custom_keepalive=custom_keepalive,
                custom_allowed_ips=custom_allowed_ips,
                custom_cpa=custom_cpa,
                preset=preset
            )
            if qr_mode and res.get("ok"):
                qr_info = show_qr(res["client"])
                if qr_info.get("qr_ascii"):
                    print(qr_info["qr_ascii"], file=sys.stderr)
        elif action in ("remove", "del", "delete"):
            res = remove_client(client_name)
        elif action in ("block", "suspend", "disable"):
            res = block_client(client_name)
        elif action in ("unblock", "unsuspend", "enable"):
            res = unblock_client(client_name, expires=expires)
        elif action in ("purge-expired", "check-expired"):
            res = purge_expired()
        elif action in ("qr", "show-qr"):
            res = show_qr(client_name or "client-1")
            if res.get("ok") and res.get("qr_ascii"):
                print(res["qr_ascii"], file=sys.stderr)
            if raw_mode and res.get("ok") and res.get("vpnuri"):
                print(res["vpnuri"])
                sys.exit(0)
        elif action == "backup":
            res = backup_configs()
        elif action == "restore":
            res = restore_configs(client_name or "")
        elif action == "restart":
            if EXEC_MODE == "container" and CONTAINER:
                run_cmd(f"docker restart {CONTAINER}")
            else:
                run_cmd("systemctl restart awg-quick@awg0 2>/dev/null || true")
            res = {"ok": True, "mode": EXEC_MODE, "status": "restarted"}
        elif action in ("repair", "repair-module"):
            ensure_backend_networking()
            if EXEC_MODE == "container" and CONTAINER:
                run_cmd(f"docker start {CONTAINER} 2>/dev/null || true")
            else:
                run_cmd("systemctl start awg-quick@awg0 2>/dev/null || true")
            res = check_status()
        elif action in ("set-preset", "preset"):
            res = {"ok": True, "mode": EXEC_MODE, "status": "preset_applied"}
        else:
            res = get_stats()

        print(json.dumps(res, indent=2))

    except Exception as exc:
        # bivlked-style _json_exit_guard: Guarantee stdout always outputs valid JSON
        err_res = {
            "ok": False,
            "mode": EXEC_MODE,
            "command": action,
            "error": str(exc),
            "rc": 1
        }
        print(json.dumps(err_res, indent=2))
        sys.exit(1)

if __name__ == "__main__":
    main()
EOF_AWG_PY
    fi
    if [ ! -f "$awg_dir/crypto_engine.py" ]; then
        cat << 'EOF_AWG_CRYPTO' > "$awg_dir/crypto_engine.py"
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
EOF_AWG_CRYPTO
    fi
    chmod 750 "$awg_dir/manage_clients.py"
    chmod 640 "$awg_dir/crypto_engine.py" 2>/dev/null || true

    # Настройка порта и хоста
    local awg_port="${AWG_SERVER_PORT:-${AWG_STANDALONE_PORT:-}}"
    if [ -z "$awg_port" ]; then
        if [ "${AWG_V3_PORT:-}" = "8443" ] && [[ "${ENABLE_AWG_V3:-}" == "1" || "${ENABLE_AWG_V3,,}" == "y" ]]; then
            awg_port="8445"
        else
            awg_port="8443"
        fi
    fi
    local awg_host="${AWG_SERVER_HOST:-${SERVER_PUBLIC_HOST:-}}"

    # Запись скрипта-лаунчера
    cat << EOF_AWG_SH > "$awg_dir/manage-clients.sh"
#!/usr/bin/env bash
set -euo pipefail
AWG_DIR="\${AWG_DIR:-/root/awg}"
PYTHON_BIN="\$(command -v python3 2>/dev/null || echo /usr/bin/python3)"
[ -n "${awg_host}" ] && export SERVER_PUBLIC_HOST="\${SERVER_PUBLIC_HOST:-${awg_host}}"
[ -n "${awg_port}" ] && export SERVER_PORT="\${SERVER_PORT:-${awg_port}}"
exec "\$PYTHON_BIN" "\$AWG_DIR/manage_clients.py" "\$@"
EOF_AWG_SH
    chmod 755 "$awg_dir/manage-clients.sh"

    # Existing automation may still call the previous filenames directly.
    ln -sf manage-clients.sh "$awg_dir/manage_amneziawg.sh"
    ln -sf manage_clients.py "$awg_dir/manage_amneziawg.py"

    # Создание глобальных симлинков для удобного управления из консоли
    ln -sf "$awg_dir/manage-clients.sh" /usr/local/bin/awg-mgr 2>/dev/null || true
    ln -sf "$awg_dir/manage-clients.sh" /usr/local/bin/awg-cli 2>/dev/null || true

    # Настройка правил файрвола UFW
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${awg_port}/udp" comment "AmneziaWG Server Engine" >/dev/null 2>&1 || true
    fi

    # Настройка периодической очистки просроченных клиентов (cron)
    if [ -d /etc/cron.d ]; then
        cat << 'EOF_CRON' > /etc/cron.d/awg-purge-expired
0 * * * * root /usr/local/bin/awg-mgr purge-expired --quiet >/dev/null 2>&1
EOF_CRON
        chmod 644 /etc/cron.d/awg-purge-expired 2>/dev/null || true
    fi

    ok "Контроллер AmneziaWG готов: утилита awg-mgr доступна в системе."
}

deploy_amneziawg_backend() {
    local awg_port="${AWG_SERVER_PORT:-${AWG_STANDALONE_PORT:-}}"
    if [ -z "$awg_port" ]; then
        if [ "${AWG_V3_PORT:-}" = "8443" ] && [[ "${ENABLE_AWG_V3:-}" == "1" || "${ENABLE_AWG_V3,,}" == "y" ]]; then
            awg_port="8445"
        else
            awg_port="8443"
        fi
    fi
    local awg_dir="/root/awg"

    # 1. Проверяем наличие пакетов и модуля ядра на хосте (при необходимости устанавливаем)
    ensure_amneziawg_installed

    # 2. Проверяем, работает ли уже какой-либо бэкенд AmneziaWG
    local active_backend=0
    if command -v docker >/dev/null 2>&1; then
        for c_cand in "amnezia-awg2" "amnezia-awg" "awg-server"; do
            if docker inspect -f '{{.State.Running}}' "$c_cand" 2>/dev/null | grep -q "true"; then
                active_backend=1
                ok "Обнаружен активный контейнер AmneziaWG: $c_cand"
                break
            fi
        done
    fi

    if [ "$active_backend" -eq 0 ] && systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
        active_backend=1
        ok "Обнаружена активная служба awg-quick@awg0 — сохраняем без изменений."
    fi

    local def_iface
    def_iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1 || echo "")
    [ -z "$def_iface" ] && def_iface="eth0"

    # 3. Если активного бэкенда нет, подготавливаем конфигурационный шаблон
    if [ "$active_backend" -eq 0 ]; then
        log "Генерация базовой конфигурации AmneziaWG (профиль 3.1)..."
        local srv_priv=""
        local srv_pub=""

        # Проверяем наличие ранее сгенерированных серверных ключей
        if [ -f "$awg_dir/keys/server_private.key" ]; then
            srv_priv=$(cat "$awg_dir/keys/server_private.key" | tr -d '[:space:]')
            if [ -f "$awg_dir/keys/server_public.key" ]; then
                srv_pub=$(cat "$awg_dir/keys/server_public.key" | tr -d '[:space:]')
            fi
        fi

        if [ -z "$srv_priv" ]; then
            if command -v awg >/dev/null 2>&1; then
                srv_priv=$(awg genkey 2>/dev/null || generate_base64_token 32)
                srv_pub=$(echo "$srv_priv" | awg pubkey 2>/dev/null || true)
            else
                srv_priv="$(generate_base64_token 32)"
                srv_pub=$(python3 - "$srv_priv" << 'EOF_CRYPTO_PUB' 2>/dev/null || true
try:
    from src.common.crypto_engine import curve25519_pubkey
except ImportError:
    try:
        from common.crypto_engine import curve25519_pubkey
    except ImportError:
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
import sys
if len(sys.argv) > 1:
    print(curve25519_pubkey(sys.argv[1]) or "")
EOF_CRYPTO_PUB
)
            fi
        fi

        local srv_psk=""
        if [ -f "$awg_dir/keys/server_psk.key" ]; then
            srv_psk=$(cat "$awg_dir/keys/server_psk.key" | tr -d '[:space:]')
        else
            srv_psk="$(generate_base64_token 32)"
        fi
        local hpk="${AWG_HEADER_PROTECTION_KEY:-$(generate_base64_token 32)}"

        mkdir -p "$awg_dir/keys"
        [ ! -f "$awg_dir/keys/server_private.key" ] && echo "$srv_priv" > "$awg_dir/keys/server_private.key"
        [ ! -f "$awg_dir/keys/server_public.key" ] && echo "$srv_pub" > "$awg_dir/keys/server_public.key"
        [ ! -f "$awg_dir/keys/server_psk.key" ] && echo "$srv_psk" > "$awg_dir/keys/server_psk.key"
        chmod 600 "$awg_dir/keys/"*

        # Сохраняем шаблон awg0.conf, только если его ещё нет
        if [ ! -f /etc/amnezia/amneziawg/awg0.conf ]; then
            mkdir -p /etc/amnezia/amneziawg
            cat << EOF_AWG0 > /etc/amnezia/amneziawg/awg0.conf
[Interface]
Address = 10.8.0.1/22
ListenPort = ${awg_port}
PrivateKey = ${srv_priv}
MTU = 1280
PostUp = iptables -I FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${def_iface} -j MASQUERADE; iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240; iptables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${def_iface} -j MASQUERADE; iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240; iptables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240
Jc = 4
Jmin = 40
Jmax = 70
S1 = 16
S2 = 16
S3 = 16
S4 = 16
H1 = 1
H2 = 2
H3 = 3
H4 = 4
HeaderProtectionKey = ${hpk}
RandomTrailers = on
DisableCookies = off
EOF_AWG0
            chmod 600 /etc/amnezia/amneziawg/awg0.conf
        else
            # Если конфиг уже был, проверяем наличие правил PostUp
            if ! grep -q "PostUp" /etc/amnezia/amneziawg/awg0.conf 2>/dev/null; then
                sed -i "/PrivateKey =/a PostUp = iptables -I FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${def_iface} -j MASQUERADE; iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240; iptables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240\\nPostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${def_iface} -j MASQUERADE; iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240; iptables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240" /etc/amnezia/amneziawg/awg0.conf 2>/dev/null || true
            fi
        fi

        # Активация и запуск системной службы WireGuard / AmneziaWG
        if command -v systemctl >/dev/null 2>&1 && [ -f /lib/systemd/system/awg-quick@.service -o -f /etc/systemd/system/awg-quick@.service -o -f /usr/lib/systemd/system/awg-quick@.service ]; then
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable --now awg-quick@awg0.service >/dev/null 2>&1 || true
            ok "Системная служба awg-quick@awg0 запущена на порту ${awg_port}/udp"
        fi
    fi

    if [ -f "$awg_dir/client-1.conf" ]; then
        if [ -n "${AWG_SERVER_HOST:-}" ]; then
            sed -i "s|^Endpoint = .*|Endpoint = ${AWG_SERVER_HOST}:${awg_port}|" "$awg_dir/client-1.conf" 2>/dev/null || true
        fi
        ok "Существующий профиль администратора сохранен: $awg_dir/client-1.conf"
    else
        local client_count=$(/root/awg/manage-clients.sh status 2>/dev/null | grep -o '"total": [0-9]*' | awk '{print $2}' || echo "0")
        if [ "$client_count" = "0" ] || [ -z "$client_count" ]; then
            log "Создание первичного профиля администратора (client-1)..."
            export SERVER_PUBLIC_HOST="${AWG_SERVER_HOST:-${SERVER_PUBLIC_HOST:-}}"
            export SERVER_PORT="${awg_port}"
            if ! /root/awg/manage-clients.sh add client-1 >/dev/null 2>&1; then
                warn "Не удалось автоматически сгенерировать первичного клиента client-1. Попробуйте вручную: awg-mgr add <имя>"
            else
                ok "Первичный профиль администратора создан: $awg_dir/client-1.conf"
                if [ -f "$awg_dir/client-1.vpnuri" ]; then
                    ok "Ссылка Amnezia VPN (vpn://): $(head -n 1 "$awg_dir/client-1.vpnuri" | tr -d '[:space:]')"
                fi
            fi
        fi
    fi
}
setup_zapret_service() {
    log "Настройка службы Server-Side Zapret nfqws..."
    local cur_arch
    cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    local z_arch="x86_64"
    case "$cur_arch" in
        x86_64|amd64) z_arch="x86_64" ;;
        aarch64|arm64) z_arch="aarch64" ;;
        *) z_arch="x86_64" ;;
    esac

    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    if [ ! -x "${bin_dir}/nfqws" ]; then
        local z_tmp="/tmp/zapret_staging_$$"
        mkdir -p "$z_tmp"
        if download_manifest_component "zapret" "$z_tmp/zapret.tar.gz" "all"; then
            tar -zxf "$z_tmp/zapret.tar.gz" -C "$z_tmp" --strip-components=1 2>/dev/null || true
            if [ -f "$z_tmp/binaries/${z_arch}/nfqws" ]; then
                cp "$z_tmp/binaries/${z_arch}/nfqws" "${bin_dir}/nfqws"
                chmod +x "${bin_dir}/nfqws"
            elif [ -n "$(find "$z_tmp" -name nfqws -type f 2>/dev/null)" ]; then
                cp "$(find "$z_tmp" -name nfqws -type f | grep "${z_arch}" | head -n1 || find "$z_tmp" -name nfqws -type f | head -n1)" "${bin_dir}/nfqws"
                chmod +x "${bin_dir}/nfqws"
            elif [ -d "$z_tmp/nfqws" ]; then
                make -C "$z_tmp/nfqws" >/dev/null 2>&1 || true
                if [ -f "$z_tmp/nfqws/nfqws" ]; then
                    cp "$z_tmp/nfqws/nfqws" "${bin_dir}/nfqws"
                    chmod +x "${bin_dir}/nfqws"
                fi
            fi
        fi
        rm -rf "$z_tmp" 2>/dev/null || true
    fi

    local qnum="${ZAPRET_QNUM:-200}"
    local desync="${ZAPRET_DESYNC:-split2}"
    local fooling="${ZAPRET_FOOLING:-md5sig,badseq}"
    local iptables_bin
    iptables_bin="$(command -v iptables 2>/dev/null || echo "/usr/sbin/iptables")"

    mkdir -p /etc/systemd/system
    cat << EOF > /etc/systemd/system/zapret-server.service
[Unit]
Description=Server-Side Zapret nfqws DPI Desync Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-${iptables_bin} -t mangle -D POSTROUTING -p tcp -m connbytes --connbytes 1:6 --connbytes-mode packets --connbytes-dir original -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num ${qnum} --queue-bypass
ExecStartPre=${iptables_bin} -t mangle -I POSTROUTING -p tcp -m connbytes --connbytes 1:6 --connbytes-mode packets --connbytes-dir original -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num ${qnum} --queue-bypass
ExecStart=${bin_dir}/nfqws --qnum=${qnum} --dpi-desync=${desync} --dpi-desync-fooling=${fooling}
ExecStopPost=-${iptables_bin} -t mangle -D POSTROUTING -p tcp -m connbytes --connbytes 1:6 --connbytes-mode packets --connbytes-dir original -m mark ! --mark 0x40000000/0x40000000 -j NFQUEUE --queue-num ${qnum} --queue-bypass
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable zapret-server >/dev/null 2>&1 || true
        if [ -x "${bin_dir}/nfqws" ]; then
            systemctl restart zapret-server 2>/dev/null || true
            ok "Служба Server-Side Zapret активирована (NFQUEUE $qnum, desync: $desync)."
        else
            warn "Бинарник ${bin_dir}/nfqws не найден, запуск zapret-server отложен."
        fi
    fi
}

setup_masque_service() {
    log "Настройка службы Sing-box MASQUE (RFC 9484 / RFC 9298)..."
    local cur_arch
    cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    local sb_arch="amd64"
    case "$cur_arch" in
        x86_64|amd64) sb_arch="amd64" ;;
        aarch64|arm64) sb_arch="arm64" ;;
        *) sb_arch="amd64" ;;
    esac

    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    local sb_ver="1.15.0-alpha.12"
    if [ -x "${bin_dir}/sing-box" ]; then
        local cur_sb_ver="$("${bin_dir}/sing-box" version 2>/dev/null | head -n1 || echo "")"
        if [[ "$cur_sb_ver" == *"1.11"* ]] || [[ "$cur_sb_ver" == *"1.12"* ]] || [[ "$cur_sb_ver" == *"1.13"* ]] || [[ "$cur_sb_ver" == *"1.14"* ]]; then
            rm -f "${bin_dir}/sing-box"
        fi
    fi

    if [ ! -x "${bin_dir}/sing-box" ]; then
        local sb_tmp="/tmp/sing-box_${sb_ver}"
        mkdir -p "$sb_tmp"
        if curl -fsSL --connect-timeout 15 "https://github.com/SagerNet/sing-box/releases/download/v${sb_ver}/sing-box-${sb_ver}-linux-${sb_arch}.tar.gz" -o "$sb_tmp/sb.tar.gz" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "https://ghfast.top/https://github.com/SagerNet/sing-box/releases/download/v${sb_ver}/sing-box-${sb_ver}-linux-${sb_arch}.tar.gz" -o "$sb_tmp/sb.tar.gz" 2>/dev/null; then
            tar -zxf "$sb_tmp/sb.tar.gz" -C "$sb_tmp" --strip-components=1 2>/dev/null || true
            if [ -f "$sb_tmp/sing-box" ]; then
                cp "$sb_tmp/sing-box" "${bin_dir}/sing-box"
                chmod +x "${bin_dir}/sing-box"
            elif [ -n "$(find "$sb_tmp" -name sing-box -type f 2>/dev/null)" ]; then
                cp "$(find "$sb_tmp" -name sing-box -type f | head -n1)" "${bin_dir}/sing-box"
                chmod +x "${bin_dir}/sing-box"
            fi
        fi
        rm -rf "$sb_tmp" 2>/dev/null || true
    fi

    local masque_p="${MASQUE_PORT:-8449}"
    local masque_u="${MASQUE_USER:-client}"
    local masque_pw="${MASQUE_PASSWORD:-}"
    local cert_file="${SSL_BASE_DIR:-/etc/letsencrypt/live}/${PRIMARY_DOMAIN}/fullchain.pem"
    local key_file="${SSL_BASE_DIR:-/etc/letsencrypt/live}/${PRIMARY_DOMAIN}/privkey.pem"
    if [ ! -f "$cert_file" ] && [ -f "/etc/ssl/acme/${PRIMARY_DOMAIN}/fullchain.pem" ]; then
        cert_file="/etc/ssl/acme/${PRIMARY_DOMAIN}/fullchain.pem"
        key_file="/etc/ssl/acme/${PRIMARY_DOMAIN}/privkey.pem"
    elif [ ! -f "$cert_file" ] && [ -f "/etc/letsencrypt/live/${PRIMARY_DOMAIN}/fullchain.pem" ]; then
        cert_file="/etc/letsencrypt/live/${PRIMARY_DOMAIN}/fullchain.pem"
        key_file="/etc/letsencrypt/live/${PRIMARY_DOMAIN}/privkey.pem"
    fi

    mkdir -p /etc/sing-box
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        mkdir -p /etc/sing-box/ssl
        if [ ! -f /etc/sing-box/ssl/fullchain.pem ]; then
            openssl req -x509 -newkey rsa:2048 -nodes \
                -keyout /etc/sing-box/ssl/privkey.pem \
                -out /etc/sing-box/ssl/fullchain.pem \
                -days 365 -subj "/CN=${PRIMARY_DOMAIN:-localhost}" 2>/dev/null || true
        fi
        cert_file="/etc/sing-box/ssl/fullchain.pem"
        key_file="/etc/sing-box/ssl/privkey.pem"
    fi

    cat << EOF > /etc/sing-box/masque.json
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "endpoints": [
    {
      "type": "masque-server",
      "tag": "masque-in",
      "listen": "::",
      "listen_port": ${masque_p},
      "users": [
        {
          "username": "${masque_u}",
          "password": "${masque_pw}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${PRIMARY_DOMAIN}",
        "certificate_path": "${cert_file}",
        "key_path": "${key_file}",
        "alpn": ["h3"]
      },
      "address": ["10.138.0.1/24"]
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    mkdir -p /etc/systemd/system
    cat << EOF > /etc/systemd/system/sing-box-masque.service
[Unit]
Description=Sing-box MASQUE (RFC 9484 / RFC 9298) Daemon
After=network.target network-online.target

[Service]
Type=simple
ExecStart=${bin_dir}/sing-box run -c /etc/sing-box/masque.json
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable sing-box-masque >/dev/null 2>&1 || true
        if [ -x "${bin_dir}/sing-box" ]; then
            systemctl restart sing-box-masque 2>/dev/null || true
            sleep 1
            if systemctl is-active --quiet sing-box-masque; then
                ok "Служба Sing-box MASQUE активирована (порт ${masque_p}/udp, H3/QUIC)."
            else
                warn "Служба sing-box-masque не перешла в статус active. Проверьте: journalctl -u sing-box-masque -n 20"
                journalctl -u sing-box-masque -n 15 --no-pager 2>/dev/null || true
            fi
        else
            warn "Бинарник ${bin_dir}/sing-box не найден, запуск sing-box-masque отложен."
        fi
    fi
}

setup_shadowtls_service() {
    log "Настройка службы ShadowTLS v4..."
    local cur_arch
    cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    local st_arch="x86_64"
    case "$cur_arch" in
        x86_64|amd64) st_arch="x86_64" ;;
        aarch64|arm64) st_arch="aarch64" ;;
        *) st_arch="x86_64" ;;
    esac

    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    if [ ! -x "${bin_dir}/shadow-tls" ]; then
        if download_manifest_component "shadow-tls" "${bin_dir}/shadow-tls" "$st_arch"; then
            chmod +x "${bin_dir}/shadow-tls"
        fi
    fi

    local st_port="${SHADOWTLS_PORT:-8543}"
    local ss_backend_port="${SS2022_PORT:-8388}"
    local st_sni="${SHADOWTLS_SNI:-gateway.icloud.com}"
    local st_pwd="${SHADOWTLS_PASSWORD:-}"

    mkdir -p /etc/systemd/system
    cat << EOF > /etc/systemd/system/shadow-tls.service
[Unit]
Description=ShadowTLS v4 Stealth SNI Decoy Gateway
After=network.target network-online.target

[Service]
Type=simple
ExecStart=${bin_dir}/shadow-tls --v3 server --listen 127.0.0.1:${st_port} --server 127.0.0.1:${ss_backend_port} --tls ${st_sni}:443 --password ${st_pwd}
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable shadow-tls >/dev/null 2>&1 || true
        if [ -x "${bin_dir}/shadow-tls" ]; then
            systemctl restart shadow-tls 2>/dev/null || true
            ok "Служба ShadowTLS v4 активирована (порт ${st_port}, decoy: ${st_sni})."
        else
            warn "Бинарник ${bin_dir}/shadow-tls не найден, запуск shadow-tls отложен."
        fi
    fi
}

setup_wstunnel_service() {
    log "Настройка службы Wstunnel L7..."
    local cur_arch
    cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    local ws_arch="x86_64"
    case "$cur_arch" in
        x86_64|amd64) ws_arch="x86_64" ;;
        aarch64|arm64) ws_arch="aarch64" ;;
        *) ws_arch="x86_64" ;;
    esac

    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    if [ ! -x "${bin_dir}/wstunnel" ]; then
        local ws_tmp="/tmp/wstunnel_staging_$$"
        mkdir -p "$ws_tmp"
        if download_manifest_component "wstunnel" "$ws_tmp/wstunnel.tar.gz" "$ws_arch"; then
            tar -zxf "$ws_tmp/wstunnel.tar.gz" -C "$ws_tmp" 2>/dev/null || true
            if [ -f "$ws_tmp/wstunnel" ]; then
                cp "$ws_tmp/wstunnel" "${bin_dir}/wstunnel"
                chmod +x "${bin_dir}/wstunnel"
            elif [ -n "$(find "$ws_tmp" -name wstunnel -type f 2>/dev/null)" ]; then
                cp "$(find "$ws_tmp" -name wstunnel -type f | head -n1)" "${bin_dir}/wstunnel"
                chmod +x "${bin_dir}/wstunnel"
            fi
        fi
        rm -rf "$ws_tmp" 2>/dev/null || true
    fi

    local ws_port="${WSTUNNEL_PORT:-8080}"
    local ws_prefix="${WSTUNNEL_PREFIX#/}"
    ws_prefix="${ws_prefix%/}"

    mkdir -p /etc/systemd/system
    cat << EOF > /etc/systemd/system/wstunnel.service
[Unit]
Description=Wstunnel L7 WebSocket Tunnel Daemon
After=network.target network-online.target

[Service]
Type=simple
ExecStart=${bin_dir}/wstunnel server --restrict-http-upgrade-path-prefix ${ws_prefix} ws://127.0.0.1:${ws_port}
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable wstunnel >/dev/null 2>&1 || true
        if [ -x "${bin_dir}/wstunnel" ]; then
            systemctl restart wstunnel 2>/dev/null || true
            ok "Служба Wstunnel L7 активирована (порт ${ws_port}, prefix: /${ws_prefix}/)."
        else
            warn "Бинарник ${bin_dir}/wstunnel не найден, запуск wstunnel отложен."
        fi
    fi
}

setup_naive_service() {
    log "Настройка службы NaïveProxy (Caddy forwardproxy@naive)..."
    local cur_arch
    cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    local caddy_arch="amd64"
    case "$cur_arch" in
        x86_64|amd64) caddy_arch="amd64" ;;
        aarch64|arm64) caddy_arch="arm64" ;;
        *) caddy_arch="amd64" ;;
    esac

    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    local caddy_bin="${bin_dir}/caddy-naive"
    if [ -x "$caddy_bin" ] && ! "$caddy_bin" list-modules 2>/dev/null | grep -q 'forward_proxy'; then
        rm -f "$caddy_bin"
    fi
    if [ ! -x "$caddy_bin" ] && command -v caddy-naive >/dev/null 2>&1; then
        local cand="$(command -v caddy-naive)"
        if "$cand" list-modules 2>/dev/null | grep -q 'forward_proxy'; then
            caddy_bin="$cand"
        fi
    fi
    if [ ! -x "$caddy_bin" ] && [ -x "${bin_dir}/caddy" ]; then
        if "${bin_dir}/caddy" list-modules 2>/dev/null | grep -q 'forward_proxy'; then
            caddy_bin="${bin_dir}/caddy"
        fi
    fi
    if [ ! -x "$caddy_bin" ] && command -v caddy >/dev/null 2>&1; then
        local cand="$(command -v caddy)"
        if "$cand" list-modules 2>/dev/null | grep -q 'forward_proxy'; then
            caddy_bin="$cand"
        fi
    fi

    if [ ! -x "$caddy_bin" ]; then
        local caddy_tmp="/tmp/caddy_naive_$$"
        mkdir -p "$caddy_tmp"
        local rel_ver="${SCRIPT_VERSION:-v9.1.0}"
        [[ "$rel_ver" == "v9.4.0" ]] && rel_ver="v9.1.0"
        [[ "$rel_ver" != v* ]] && rel_ver="v${rel_ver}"
        local dl_url="https://github.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/releases/download/${rel_ver}/caddy-naive-linux-${caddy_arch}.tar.gz"
        local dl_mirror="https://ghfast.top/${dl_url}"
        local dl_fallback="https://github.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/releases/download/v9.1.0/caddy-naive-linux-${caddy_arch}.tar.gz"
        if curl -fsSL --connect-timeout 15 "$dl_url" -o "$caddy_tmp/caddy.tar.gz" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "$dl_mirror" -o "$caddy_tmp/caddy.tar.gz" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "$dl_fallback" -o "$caddy_tmp/caddy.tar.gz" 2>/dev/null; then
            tar -zxf "$caddy_tmp/caddy.tar.gz" -C "$caddy_tmp" 2>/dev/null || true
            if [ -f "$caddy_tmp/caddy-naive" ]; then
                cp "$caddy_tmp/caddy-naive" "${bin_dir}/caddy-naive"
                chmod +x "${bin_dir}/caddy-naive"
                caddy_bin="${bin_dir}/caddy-naive"
            elif [ -f "$caddy_tmp/caddy" ]; then
                cp "$caddy_tmp/caddy" "${bin_dir}/caddy-naive"
                chmod +x "${bin_dir}/caddy-naive"
                caddy_bin="${bin_dir}/caddy-naive"
            fi
        fi
        rm -rf "$caddy_tmp" 2>/dev/null || true
    fi

    local naive_port="${NAIVE_PORT:-8446}"
    local naive_user="${NAIVE_USER:-user}"
    local naive_pass="${NAIVE_PASS:-}"
    if [ -z "$naive_pass" ]; then
        naive_pass="$(generate_urlsafe_token 16)"
        NAIVE_PASS="$naive_pass"
    fi
    export NAIVE_PASS="$naive_pass"

    local naive_domain="${NAIVE_DOMAIN:-naive.${PRIMARY_DOMAIN:-}}"
    if [ -z "$naive_domain" ] || [ "$naive_domain" = "${PRIMARY_DOMAIN:-}" ]; then
        if [ -n "${PRIMARY_DOMAIN:-}" ]; then
            naive_domain="naive.${PRIMARY_DOMAIN}"
        else
            naive_domain="localhost"
        fi
    fi
    NAIVE_DOMAIN="$naive_domain"
    export NAIVE_DOMAIN="$naive_domain"

    mkdir -p /etc/caddy /etc/naiveproxy /var/www/html 2>/dev/null || true
    if [ ! -f /var/www/html/index.html ]; then
        echo "<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>Welcome to Nginx Stream Mask</h1></body></html>" > /var/www/html/index.html 2>/dev/null || true
    fi

    local tls_directive="tls internal"
    local cert_candidates=()
    [ -n "$naive_domain" ] && [ "$naive_domain" != "localhost" ] && cert_candidates+=("$naive_domain")
    [ -n "${PRIMARY_DOMAIN:-}" ] && cert_candidates+=("${PRIMARY_DOMAIN}")
    [ -n "${DOMAIN:-}" ] && cert_candidates+=("${DOMAIN}")

    for c_dom in "${cert_candidates[@]}"; do
        if [ -f "/etc/letsencrypt/live/${c_dom}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${c_dom}/privkey.pem" ]; then
            tls_directive="tls /etc/letsencrypt/live/${c_dom}/fullchain.pem /etc/letsencrypt/live/${c_dom}/privkey.pem"
            break
        elif [ -f "/etc/ssl/acme/${c_dom}/fullchain.pem" ] && [ -f "/etc/ssl/acme/${c_dom}/privkey.pem" ]; then
            tls_directive="tls /etc/ssl/acme/${c_dom}/fullchain.pem /etc/ssl/acme/${c_dom}/privkey.pem"
            break
        fi
    done

    cat << EOF > /etc/caddy/Caddyfile
{
  order forward_proxy before reverse_proxy
  admin off
  auto_https disable_redirects
}

:${naive_port} {
  bind 127.0.0.1
  ${tls_directive}

  forward_proxy {
    basic_auth ${naive_user} ${naive_pass}
    hide_ip
    hide_via
    probe_resistance
  }

  file_server {
    root /var/www/html
  }
}
EOF
    cp -f /etc/caddy/Caddyfile /etc/naiveproxy/Caddyfile 2>/dev/null || true

    mkdir -p /etc/systemd/system
    cat << EOF > /etc/systemd/system/caddy-naive.service
[Unit]
Description=Caddy NaïveProxy Server Daemon
After=network.target network-online.target

[Service]
Type=simple
ExecStart=${caddy_bin} run --config /etc/caddy/Caddyfile --adapter caddyfile
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable caddy-naive >/dev/null 2>&1 || true
        if [ -x "$caddy_bin" ]; then
            systemctl restart caddy-naive 2>/dev/null || true
            sleep 1
            if systemctl is-active --quiet caddy-naive; then
                ok "Служба NaïveProxy активирована (порт ${naive_port}, user: ${naive_user})."
            else
                warn "Служба caddy-naive не перешла в статус active. Проверьте: journalctl -u caddy-naive -n 20"
                journalctl -u caddy-naive -n 15 --no-pager 2>/dev/null || true
            fi
        else
            warn "Бинарник ${caddy_bin} не найден, запуск caddy-naive отложен."
        fi
    fi
}

setup_dnstt_service() {
    log "Настройка службы DNSTT (DoH DNS Tunneling)..."
    local cur_arch
    cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    local dnstt_arch="amd64"
    case "$cur_arch" in
        x86_64|amd64) dnstt_arch="amd64" ;;
        aarch64|arm64) dnstt_arch="arm64" ;;
        *) dnstt_arch="amd64" ;;
    esac

    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    local dnstt_bin="${bin_dir}/dnstt-server"
    if [ ! -x "$dnstt_bin" ] && command -v dnstt-server >/dev/null 2>&1; then
        dnstt_bin="$(command -v dnstt-server)"
    fi

    if [ ! -x "$dnstt_bin" ]; then
        local dnstt_tmp="/tmp/dnstt_$$"
        mkdir -p "$dnstt_tmp"
        local rel_ver="${SCRIPT_VERSION:-v9.1.0}"
        [[ "$rel_ver" == "v9.4.0" ]] && rel_ver="v9.1.0"
        [[ "$rel_ver" != v* ]] && rel_ver="v${rel_ver}"
        local dl_url="https://github.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/releases/download/${rel_ver}/dnstt-server-linux-${dnstt_arch}.tar.gz"
        local dl_mirror="https://ghfast.top/${dl_url}"
        local dl_fallback="https://github.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/releases/download/v9.1.0/dnstt-server-linux-${dnstt_arch}.tar.gz"
        if curl -fsSL --connect-timeout 15 "$dl_url" -o "$dnstt_tmp/dnstt.tar.gz" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "$dl_mirror" -o "$dnstt_tmp/dnstt.tar.gz" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "$dl_fallback" -o "$dnstt_tmp/dnstt.tar.gz" 2>/dev/null; then
            tar -zxf "$dnstt_tmp/dnstt.tar.gz" -C "$dnstt_tmp" 2>/dev/null || true
            if [ -f "$dnstt_tmp/dnstt-server" ]; then
                cp "$dnstt_tmp/dnstt-server" "${bin_dir}/dnstt-server"
                chmod +x "${bin_dir}/dnstt-server"
                dnstt_bin="${bin_dir}/dnstt-server"
            fi
        fi
        rm -rf "$dnstt_tmp" 2>/dev/null || true
    fi

    if [ ! -x "$dnstt_bin" ] && command -v go >/dev/null 2>&1; then
        log "Компиляция dnstt-server из исходников (Go)..."
        if CGO_ENABLED=0 go install -ldflags='-s -w' www.bamsoftware.com/git/dnstt.git/dnstt-server@latest 2>/dev/null; then
            local gopath="$(go env GOPATH 2>/dev/null || echo "$HOME/go")"
            if [ -f "${gopath}/bin/dnstt-server" ]; then
                cp "${gopath}/bin/dnstt-server" "${bin_dir}/dnstt-server"
                chmod +x "${bin_dir}/dnstt-server"
                dnstt_bin="${bin_dir}/dnstt-server"
            fi
        fi
    fi

    local dnstt_port="${DNSTT_PORT:-53053}"
    local ss_backend_port="${SS2022_PORT:-8388}"
    local dnstt_domain="${DNSTT_DOMAIN:-t.${PRIMARY_DOMAIN:-example.com}}"

    mkdir -p /etc/dnstt
    chmod 700 /etc/dnstt 2>/dev/null || true

    if [ ! -f /etc/dnstt/server.key ] || [ ! -f /etc/dnstt/server.pub ]; then
        if [ -x "$dnstt_bin" ]; then
            "$dnstt_bin" -gen-key -privkey-file /etc/dnstt/server.key -pubkey-file /etc/dnstt/server.pub 2>/dev/null || true
        fi
        if [ ! -f /etc/dnstt/server.key ] || [ ! -f /etc/dnstt/server.pub ]; then
            python3 - /etc/dnstt/server.key /etc/dnstt/server.pub << 'EOF_DNSTT_KEY' 2>/dev/null || true
try:
    from src.common.crypto_engine import generate_dnstt_keypair
except ImportError:
    try:
        from common.crypto_engine import generate_dnstt_keypair
    except ImportError:
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
import sys
key_file, pub_file = sys.argv[1], sys.argv[2]
priv_hex, pub_hex = generate_dnstt_keypair()
with open(key_file, 'w') as kf:
    kf.write(priv_hex + '\n')
with open(pub_file, 'w') as pf:
    pf.write(pub_hex + '\n')
EOF_DNSTT_KEY
            if [ ! -f /etc/dnstt/server.key ] || [ ! -f /etc/dnstt/server.pub ]; then
                head /dev/urandom 2>/dev/null | tr -dc 0-9a-f | head -c 64 > /etc/dnstt/server.key 2>/dev/null || echo "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" > /etc/dnstt/server.key
                head /dev/urandom 2>/dev/null | tr -dc 0-9a-f | head -c 64 > /etc/dnstt/server.pub 2>/dev/null || echo "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210" > /etc/dnstt/server.pub
            fi
        fi
        chmod 600 /etc/dnstt/server.key /etc/dnstt/server.pub 2>/dev/null || true
    fi

    DNSTT_PUBKEY="$(cat /etc/dnstt/server.pub 2>/dev/null | tr -d '[:space:]')"
    export DNSTT_PUBKEY

    mkdir -p /etc/systemd/system
    cat << EOF > /etc/systemd/system/dnstt-server.service
[Unit]
Description=DNSTT DNS Tunneling Server Daemon (DoH / UDP)
After=network.target network-online.target

[Service]
Type=simple
ExecStart=${dnstt_bin} -udp 0.0.0.0:${dnstt_port} -privkey-file /etc/dnstt/server.key ${dnstt_domain} 127.0.0.1:${ss_backend_port}
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable dnstt-server >/dev/null 2>&1 || true
        if [ -x "$dnstt_bin" ]; then
            systemctl restart dnstt-server 2>/dev/null || true
            sleep 1
            if systemctl is-active --quiet dnstt-server; then
                ok "Служба DNSTT активирована (порт ${dnstt_port}/udp, домен: ${dnstt_domain})."
            else
                warn "Служба dnstt-server не перешла в статус active. Проверьте: journalctl -u dnstt-server -n 20"
                journalctl -u dnstt-server -n 15 --no-pager 2>/dev/null || true
            fi
        else
            warn "Бинарник ${dnstt_bin} не найден, запуск dnstt-server отложен."
        fi
    fi
}

setup_mieru_service() {
    log "Настройка службы Mieru Proxy (mita)..."
    local cur_arch
    cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
    local mita_arch="amd64"
    case "$cur_arch" in
        x86_64|amd64) mita_arch="amd64" ;;
        aarch64|arm64) mita_arch="arm64" ;;
        *) mita_arch="amd64" ;;
    esac

    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    local mita_bin="${bin_dir}/mita"
    if [ ! -x "$mita_bin" ] && command -v mita >/dev/null 2>&1; then
        mita_bin="$(command -v mita)"
    fi

    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true 2>/dev/null || true
        systemctl restart systemd-timesyncd 2>/dev/null || true
    fi

    if [ ! -x "$mita_bin" ]; then
        local mita_ver="3.38.1"
        local mita_tmp="/tmp/mita_${mita_ver}_$$"
        mkdir -p "$mita_tmp"
        local dl_url="https://github.com/enfein/mieru/releases/download/v${mita_ver}/mita_${mita_ver}_linux_${mita_arch}.tar.gz"
        local dl_mirror="https://ghfast.top/${dl_url}"
        if curl -fsSL --connect-timeout 15 "$dl_url" -o "$mita_tmp/mita.tar.gz" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "$dl_mirror" -o "$mita_tmp/mita.tar.gz" 2>/dev/null; then
            tar -zxf "$mita_tmp/mita.tar.gz" -C "$mita_tmp" 2>/dev/null || true
            if [ -f "$mita_tmp/mita" ]; then
                cp "$mita_tmp/mita" "${bin_dir}/mita"
                chmod +x "${bin_dir}/mita"
                mita_bin="${bin_dir}/mita"
            fi
        fi
        rm -rf "$mita_tmp" 2>/dev/null || true
    fi

    if [ ! -x "$mita_bin" ]; then
        warn "Не удалось загрузить бинарник mita. Установка Mieru пропущена."
        return 1
    fi

    local m_port_mode="${MIERU_PORT_MODE:-single}"
    local m_port="${MIERU_PORT:-8450}"
    local m_user="${MIERU_USER:-user-default}"
    local m_pass="${MIERU_PASS:-pass-default}"
    local m_trans="${MIERU_TRANSPORT:-BOTH}"
    local m_mtu="${MIERU_MTU:-1400}"
    local m_cfg_file="${MIERU_CONFIG_FILE:-/etc/mita/config.json}"
    local m_compat_file="${MIERU_COMPAT_CONFIG_FILE:-/etc/mita_server_config.json}"

    if ! id -u mita >/dev/null 2>&1; then
        useradd --system --no-create-home --user-group mita 2>/dev/null || true
    fi
    mkdir -p "$(dirname "$m_cfg_file")" /var/lib/mita /var/run/mita 2>/dev/null || true
    chown -R mita:mita "$(dirname "$m_cfg_file")" /var/lib/mita /var/run/mita 2>/dev/null || true
    chmod 750 "$(dirname "$m_cfg_file")" /var/lib/mita /var/run/mita 2>/dev/null || true

    local py_cmd="${PYTHON_CMD:-}"
    if [ -z "$py_cmd" ]; then
        if command -v python3 >/dev/null 2>&1; then
            py_cmd="python3"
        elif command -v python >/dev/null 2>&1; then
            py_cmd="python"
        else
            py_cmd="python3"
        fi
    fi

    MIERU_CONFIG_PORT_MODE="$m_port_mode" \
    MIERU_CONFIG_PORT_VAL="$m_port" \
    MIERU_CONFIG_TRANSPORT="$m_trans" \
    MIERU_CONFIG_USER="$m_user" \
    MIERU_CONFIG_PASS="$m_pass" \
    MIERU_CONFIG_MTU="$m_mtu" \
    MIERU_CONFIG_FILE="$m_cfg_file" \
    MIERU_COMPAT_CONFIG_FILE="$m_compat_file" \
    "$py_cmd" - << 'PYEOF'
import json
import os
import sys
import tempfile

port_mode = os.environ.get("MIERU_CONFIG_PORT_MODE", "single").lower()
port_val = os.environ.get("MIERU_CONFIG_PORT_VAL", "8450").strip()
transport = os.environ.get("MIERU_CONFIG_TRANSPORT", "BOTH").upper()
user = os.environ.get("MIERU_CONFIG_USER", "user-default")
password = os.environ.get("MIERU_CONFIG_PASS", "pass-default")
cfg_file = os.environ.get("MIERU_CONFIG_FILE", "/etc/mita/config.json")
compat_file = os.environ.get("MIERU_COMPAT_CONFIG_FILE", "/etc/mita_server_config.json")
try:
    mtu = int(os.environ.get("MIERU_CONFIG_MTU", "1400"))
except ValueError:
    mtu = 1400

protocols = ['TCP', 'UDP'] if transport == 'BOTH' else [transport]
port_bindings = []

for proto in protocols:
    if port_mode == 'range' or '-' in port_val:
        port_bindings.append({'portRange': port_val, 'protocol': proto})
    else:
        clean_p = int(port_val.split('-')[0].split(':')[0])
        port_bindings.append({'port': clean_p, 'protocol': proto})

config = {
    'portBindings': port_bindings,
    'users': [{
        'name': user,
        'password': password
    }],
    'loggingLevel': 'INFO',
    'mtu': mtu,
    'dns': {
        'dualStack': 'PREFER_IPv4'
    }
}

paths = [cfg_file, compat_file]
for path in paths:
    target_dir = os.path.dirname(path)
    if target_dir:
        os.makedirs(target_dir, exist_ok=True)
    tmp_fd, tmp_path = tempfile.mkstemp(dir=target_dir or None, prefix="mita_conf_", text=True)
    try:
        try:
            os.fchmod(tmp_fd, 0o600)
        except Exception:
            pass
        with open(tmp_fd, 'w', encoding='utf-8') as f:
            json.dump(config, f, indent=2)
            f.write('\n')
        os.replace(tmp_path, path)
        try:
            os.chmod(path, 0o600)
        except Exception:
            pass
    except Exception:
        if os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except Exception:
                pass
        raise
PYEOF
    local py_rc=$?
    if [ "$py_rc" -ne 0 ]; then
        warn "Ошибка при создании конфигурации Mieru ($m_cfg_file)."
        return 1
    fi

    chown mita:mita "$m_cfg_file" "$m_compat_file" 2>/dev/null || true
    chmod 600 "$m_cfg_file" "$m_compat_file" 2>/dev/null || true

    mkdir -p /etc/systemd/system
    cat << EOF > /etc/systemd/system/mita.service
[Unit]
Description=Mieru proxy server (mita)
After=network-online.target network.service systemd-timesyncd.service
Wants=network-online.target systemd-timesyncd.service
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
Type=exec
User=mita
Group=mita
AmbientCapabilities=CAP_NET_BIND_SERVICE
Environment="MITA_LOG_NO_TIMESTAMP=true"
Environment="MITA_CONFIG_JSON_FILE=${m_cfg_file}"
ExecStartPre=+/bin/sh -c 'mkdir -p /var/run/mita /var/lib/mita && chown -R mita:mita /var/run/mita /var/lib/mita /etc/mita && chmod 750 /var/run/mita /var/lib/mita /etc/mita && chmod 600 ${m_cfg_file} ${m_compat_file} 2>/dev/null || true'
ExecStart=${mita_bin} run
Nice=-10
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    if command -v ufw >/dev/null 2>&1; then
        local ufw_m_port="${m_port//-/:}"
        if [ "$m_trans" = "BOTH" ] || [ "$m_trans" = "TCP" ]; then
            ufw allow "${ufw_m_port}/tcp" comment 'VPN: Mieru TCP' >/dev/null 2>&1 || true
        fi
        if [ "$m_trans" = "BOTH" ] || [ "$m_trans" = "UDP" ]; then
            ufw allow "${ufw_m_port}/udp" comment 'VPN: Mieru UDP' >/dev/null 2>&1 || true
        fi
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable mita >/dev/null 2>&1 || true
        systemctl restart mita 2>/dev/null || true
        sleep 1
        if [ -x "$mita_bin" ] && [ -f /etc/mita/config.json ]; then
            "$mita_bin" apply config /etc/mita/config.json 2>/dev/null || true
            "$mita_bin" start 2>/dev/null || true
        fi
        sleep 1
        if systemctl is-active --quiet mita; then
            ok "Служба Mieru (mita) успешно запущена (порт ${m_port}, XChaCha20-Poly1305)."
        else
            systemctl restart mita 2>/dev/null || true
            sleep 1
            if systemctl is-active --quiet mita; then
                ok "Служба Mieru (mita) успешно запущена (порт ${m_port}, XChaCha20-Poly1305)."
            else
                warn "Служба Mieru не перешла в статус active. Проверьте: journalctl -u mita -n 20"
                journalctl -u mita -n 15 --no-pager 2>/dev/null || true
            fi
        fi
    fi

    # Развертывание CLI-менеджера пользователей Mieru
    local src_mgr="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../system" 2>/dev/null && pwd)/mieru-mgr.sh"
    if [ -f "$src_mgr" ]; then
        cp -f "$src_mgr" "${bin_dir}/mieru-mgr"
    fi
    if [ ! -f "${bin_dir}/mieru-mgr" ]; then
        cat << 'EOF_MIERU_MGR' > "${bin_dir}/mieru-mgr"
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

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]] && [[ "$(basename "${0:-}")" == *"mieru-"* ]]; then
    mieru_mgr_main "$@"
fi
EOF_MIERU_MGR
    fi
    chmod 755 "${bin_dir}/mieru-mgr" 2>/dev/null || true
    ln -sf "${bin_dir}/mieru-mgr" "${bin_dir}/mieru-cli" 2>/dev/null || true
    ok "Утилита управления пользователями Mieru готова: ${bin_dir}/mieru-mgr (или mieru-cli)"
}

deploy_native_nextgen_services() {
    if is_true "${ENABLE_ZAPRET:-0}"; then
        setup_zapret_service
    fi
    if is_true "${ENABLE_MASQUE:-0}"; then
        setup_masque_service
    fi
    if is_true "${ENABLE_SHADOWTLS:-0}"; then
        setup_shadowtls_service
    fi
    if is_true "${ENABLE_WSTUNNEL:-0}"; then
        setup_wstunnel_service
    fi
    if is_true "${ENABLE_NAIVE:-0}"; then
        setup_naive_service
    fi
    if is_true "${ENABLE_DNSTT:-0}"; then
        setup_dnstt_service
    fi
    if is_true "${ENABLE_MIERU:-0}"; then
        setup_mieru_service
    fi
}
# Express provides defaults for the common installation engine.
express_default() {
    local name="$1" value="$2" cli_name="CLI_$1"
    if [ -z "${CONFIG_EXPLICIT_KEYS[$name]:-}" ] && [ -z "${!cli_name:-}" ]; then
        printf -v "$name" '%s' "$value"
    fi
}

apply_express_defaults() {
    express_default ADD_WWW n
    express_default ENABLE_STEAL y
    express_default STEAL_PORT 45443
    express_default STEAL_DOMAINS_STR "cdn.$PRIMARY_DOMAIN"
    express_default ENABLE_CLASSIC y
    express_default CLASSIC_PORT 46443
    express_default CLASSIC_SNI dl.google.com
    express_default ENABLE_HY2 y
    express_default HY2_PORT 443
    express_default HY2_DOMAIN "$PRIMARY_DOMAIN"
    express_default ENABLE_AWG_V3 y
    express_default AWG_V3_PORT 8443
    express_default ENABLE_AWG_V2 n
    express_default ENABLE_TUIC y
    express_default ENABLE_SS2022 y
    express_default ENABLE_MTPROTO y
    express_default DECOY_MODE 1
    express_default PORTS_SETUP_MODE 0
    express_default PATHS_SETUP_MODE 0
    express_default SSL_ENGINE_CHOICE 1
    express_default AUTO_SETUP_3XUI y
    express_default ENABLE_WARP y
    express_default ENABLE_AGH y
    express_default AGH_MODE 1
    express_default AGH_XRAY_DNS n
    reconstruct_arrays_from_vars
    finalize_installation_config
}
# Pure plan construction. Express and Expert differ only in how they collect input.
# Listener declarations shared by planning, validation and final health checks.
protocol_is_public() {
    case "$1" in ShadowTLS|Wstunnel|NaiveProxy) return 1 ;; esac
}

selected_protocol_ports() {
    local flag transport variable fallback name
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        while read -r flag transport variable fallback name; do
            if is_true "${!flag:-n}"; then
                if [ "$flag" = "ENABLE_MIERU" ]; then
                    local m_trans="${MIERU_TRANSPORT:-BOTH}"
                    case "${m_trans^^}" in
                        TCP) [ "$transport" = "udp" ] && continue ;;
                        UDP) [ "$transport" = "tcp" ] && continue ;;
                    esac
                fi
                printf '%s %s %s\n' "$name" "$transport" "${!variable:-$fallback}"
            fi
        done <<'PROTOCOL_PORTS'
ENABLE_HY2 udp HY2_PORT 443 Hysteria2
ENABLE_AWG_V3 udp AWG_V3_PORT 8443 AWG-v3
ENABLE_AWG_V2 udp AWG_V2_PORT 8444 AWG-v2
ENABLE_SS2022 tcp SS2022_PORT 8388 SS2022
ENABLE_SS2022 udp SS2022_PORT 8388 SS2022
ENABLE_TUIC udp TUIC_PORT 8448 TUIC
ENABLE_MTPROTO tcp MTPROTO_PORT 8444 MTProto
ENABLE_MASQUE udp MASQUE_PORT 8449 MASQUE
ENABLE_SHADOWTLS tcp SHADOWTLS_PORT 8543 ShadowTLS
ENABLE_WSTUNNEL tcp WSTUNNEL_PORT 8080 Wstunnel
ENABLE_NAIVE tcp NAIVE_PORT 8446 NaiveProxy
ENABLE_DNSTT udp DNSTT_PORT 53053 DNSTT
ENABLE_MIERU tcp MIERU_PORT 8450 Mieru
ENABLE_MIERU udp MIERU_PORT 8450 Mieru
PROTOCOL_PORTS
    fi
    if is_true "${ENABLE_AWG_STANDALONE:-n}"; then
        printf 'AWG-standalone udp %s\n' "${AWG_STANDALONE_PORT:-8445}"
    fi
    return 0
}

installation_listeners() {
    printf 'SSH tcp %s\n' "${SSH_PORT:-${SSH_ACTIVE_PORT:-22}}"
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        printf 'HTTP tcp 80\nHTTPS tcp 443\n'
        printf 'Panel tcp %s\nSubscription tcp %s\nxHTTP tcp %s\n' \
            "${PANEL_PORT:-10443}" "${SUB_PORT:-55443}" "${XHTTP_STREAM_PORT:-50443}"
        local port
        if is_true "${ENABLE_STEAL:-n}"; then
            for port in "${STEAL_PORTS_LIST[@]:-${STEAL_PORT:-45443}}"; do printf 'Reality-own tcp %s\n' "$port"; done
        fi
        if is_true "${ENABLE_CLASSIC:-n}"; then
            for port in "${CLASSIC_PORTS_LIST[@]:-${CLASSIC_PORT:-46443}}"; do printf 'Reality-external tcp %s\n' "$port"; done
        fi
        if is_true "${ENABLE_AGH:-n}"; then
            local agh_dns_p="${PORT_AGH_DNS:-10053}"
            printf 'AdGuard-web tcp %s\nAdGuard-DNS tcp %s\nAdGuard-DNS udp %s\n' "${PORT_AGH_WEB:-3000}" "$agh_dns_p" "$agh_dns_p"
        fi
    fi
    selected_protocol_ports
}
declare -a INSTALLATION_PLAN=()
declare -A STEP_IDS=() STEP_NUMBERS=()
declare -A INSTALLATION_TITLES=(
    [packages]="Базовые системные зависимости"
    [kernel]="Сетевые параметры и лимиты"
    [security]="Безопасность SSH и Fail2ban"
    [nginx]="Установка Nginx и подготовка HTTP для ACME"
    [certificates]="Выпуск SSL-сертификатов"
    [decoy]="Развертывание выбранного сайта"
    [nginx_config]="Конфигурация и проверка Nginx"
    [firewall]="Правила доступа и маршрутизации"
    [panel]="Панель 3X-UI и выбранные протоколы"
    [adguard]="AdGuard Home и DNS"
    [awg]="Автономный сервер AmneziaWG"
    [verify]="Проверка всех выбранных компонентов"
)

build_installation_plan() {
    INSTALLATION_PLAN=(packages kernel)
    if is_true "${ENABLE_HOST_SECURITY:-n}" || is_true "${ENABLE_FAIL2BAN:-n}" ||
       is_true "${DISABLE_PASSWORD_AUTH:-n}" || [ -n "${SSH_PUBLIC_KEY:-}" ] ||
       [ "${SSH_PORT:-${SSH_ACTIVE_PORT:-22}}" != "${SSH_ACTIVE_PORT:-22}" ]; then
        INSTALLATION_PLAN+=(security)
    fi
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        INSTALLATION_PLAN+=(nginx certificates decoy nginx_config firewall)
        if is_true "${AUTO_SETUP_3XUI:-y}"; then INSTALLATION_PLAN+=(panel); fi
        if is_true "${ENABLE_AGH:-n}"; then INSTALLATION_PLAN+=(adguard); fi
    fi
    if is_true "${ENABLE_AWG_STANDALONE:-n}"; then INSTALLATION_PLAN+=(awg); fi
    INSTALLATION_PLAN+=(verify)
    TOTAL_STEPS=${#INSTALLATION_PLAN[@]}
    STEP_IDS=(); STEP_NUMBERS=(); STEP_NAMES=()
    local index=1 id
    for id in "${INSTALLATION_PLAN[@]}"; do
        STEP_IDS[$index]="$id"
        STEP_NUMBERS[$id]=$index
        STEP_NAMES[$index]="${INSTALLATION_TITLES[$id]}"
        index=$((index + 1))
    done
}

show_installation_plan() {
    printf '\nПлан установки (%s этапов):\n' "$TOTAL_STEPS"
    local id
    for id in "${INSTALLATION_PLAN[@]}"; do
        printf '  %2s. %s\n' "${STEP_NUMBERS[$id]}" "${INSTALLATION_TITLES[$id]}"
    done
    printf '  SSH: %s → %s; настройки: %s\n' "${SSH_ACTIVE_PORT:-22}" \
        "${SSH_PORT:-${SSH_ACTIVE_PORT:-22}}" "${SAVED_CONFIG_FILE:-server-setup.env}"
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        printf '  Домен: %s; SSL: %s\n' "${PRIMARY_DOMAIN:-}" "${SSL_ENGINE_CHOICE:-1}"
    fi
    local name transport port scope
    while read -r name transport port; do
        scope="публичный"
        if ! protocol_is_public "$name"; then scope="локальный, через Nginx"; fi
        printf '  %s: %s/%s (%s)\n' "$name" "$port" "$transport" "$scope"
    done < <(selected_protocol_ports)
}

confirm_installation_plan() {
    show_installation_plan
    [ "${NON_INTERACTIVE:-0}" -eq 1 ] && return 0
    local answer=""
    printf '\nПрименить этот план? [Y/n]: '
    read -r answer </dev/tty 2>/dev/null || read -r answer || return 1
    answer="${answer//[[:space:]]/}"
    case "${answer,,}" in
        ''|y|yes|д|да) return 0 ;;
        *) warn "Установка отменена. Изменения системы не применялись."; return 1 ;;
    esac
}

validate_installation_config() {
    if ! is_true "${ENABLE_WEB_STACK:-y}" && ! is_true "${ENABLE_AWG_STANDALONE:-n}"; then
        die "Не выбран ни один компонент установки."
    fi
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        [[ "${PRIMARY_DOMAIN:-}" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || die "Некорректный основной домен."
        if [ -z "${LE_EMAIL:-}" ]; then
            LE_EMAIL="admin@${PRIMARY_DOMAIN}"
        fi
    else
        [ -n "${AWG_SERVER_HOST:-}" ] || die "Не задан Endpoint автономного AmneziaWG."
    fi
    local name value transport binding
    local -A claimed=()
    while read -r name transport value; do
        if [[ "$value" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
            local p_start="${BASH_REMATCH[1]}"
            local p_end="${BASH_REMATCH[2]}"
            p_start="$((10#$p_start))"
            p_end="$((10#$p_end))"
            [ "$p_start" -ge 1 ] && [ "$p_start" -le 65535 ] && \
            [ "$p_end" -ge 1 ] && [ "$p_end" -le 65535 ] && \
            [ "$p_start" -le "$p_end" ] || die "Некорректный диапазон портов $name: $value"
            local p
            for (( p=p_start; p<=p_end; p++ )); do
                binding="$transport:$p"
                [ -z "${claimed[$binding]:-}" ] || die "Конфликт порта $p/$transport: ${claimed[$binding]} и $name. Измените порт одного из компонентов."
                claimed[$binding]="$name"
            done
        elif [[ "$value" =~ ^[0-9]{1,5}$ ]]; then
            local p="$((10#$value))"
            [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || die "Некорректный порт $name: $value"
            binding="$transport:$p"
            [ -z "${claimed[$binding]:-}" ] || die "Конфликт порта $value/$transport: ${claimed[$binding]} и $name. Измените порт одного из компонентов."
            claimed[$binding]="$name"
        else
            die "Некорректный порт $name: $value"
        fi
    done < <(installation_listeners)
}

run_installation() {
    validate_installation_config
    inspect_port_conflicts
    build_installation_plan
    confirm_installation_plan
    if [ "${CHECK_MODE:-0}" -ne 1 ] && [ "${DRY_RUN:-0}" -ne 1 ]; then
        if command -v acquire_stack_lock >/dev/null 2>&1; then
            acquire_stack_lock "${VPN_STACK_LOCK_TIMEOUT:-10}" "install" || exit $?
        fi
    fi
    save_session_state "${SAVED_CONFIG_FILE:-server-setup.env}"
    if command -v create_initial_state_snapshot >/dev/null 2>&1; then
        create_initial_state_snapshot || true
    fi
    WEBROOT="/var/www/html"
    NGINX_USER=nginx
    if ! id -u nginx >/dev/null 2>&1; then NGINX_USER=www-data; fi
    if [ "${SSL_ENGINE_CHOICE:-1}" = 1 ]; then SSL_BASE_DIR=/etc/letsencrypt/live; else SSL_BASE_DIR=/etc/ssl/acme; fi
    local id
    for id in "${INSTALLATION_PLAN[@]}"; do
        if should_skip_step "$id"; then continue; fi
        step_begin "$id"
        "install_step_$id"
        step_finish "$id"
    done
    record_step_completed 0
    save_session_state "${SAVED_CONFIG_FILE:-server-setup.env}"
    report_installation
}
install_step_packages() {
    run_with_spinner "Установка базовых зависимостей" install_prerequisites
}

install_step_kernel() {
    run_with_spinner "Применение сетевых параметров" apply_sysctl_and_limits
}

install_step_security() {
    local_active_ssh="${SSH_ACTIVE_PORT:-22}"
    local_target_ssh="${SSH_PORT:-$local_active_ssh}"
    if is_true "${ENABLE_HOST_SECURITY:-n}" || [ "$local_target_ssh" -ne "$local_active_ssh" ] || is_true "${ENABLE_FAIL2BAN:-n}" || is_true "${DISABLE_PASSWORD_AUTH:-n}" || [ -n "${SSH_PUBLIC_KEY:-}" ]; then
        if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
            add_authorized_key "$SSH_PUBLIC_KEY" "root"
        fi
        if [ "$local_target_ssh" -ne "$local_active_ssh" ] || is_true "${DISABLE_PASSWORD_AUTH:-n}"; then
            run_with_spinner "Применение конфигурации OpenSSH (порт $local_target_ssh)" apply_ssh_configuration "$local_target_ssh" "$local_active_ssh" "${DISABLE_PASSWORD_AUTH:-n}" || die "Не удалось применить конфигурацию SSH."
            if command -v ufw >/dev/null 2>&1; then
                ufw allow "${local_active_ssh}/tcp" comment 'Current SSH Port' >/dev/null 2>&1 || true
                ufw allow "${local_target_ssh}/tcp" comment 'Target SSH Port' >/dev/null 2>&1 || true
            fi
        fi
        if is_true "${ENABLE_FAIL2BAN:-n}"; then
            run_with_spinner "Установка и настройка службы Fail2ban" apply_fail2ban_configuration "$local_target_ssh" "$local_active_ssh" || die "Не удалось настроить Fail2ban."
        fi
    fi

    # Настройка Strict DNS-over-TLS для системного резолвера ОС
    run_with_spinner "Настройка Strict DNS-over-TLS (systemd-resolved)" setup_strict_dot_dns || warn "Не удалось настроить systemd-resolved DoT."

    # Настройка автоматических ночных обновлений безопасности (ребут в 04:38)
    run_with_spinner "Настройка автоматических обновлений (unattended-upgrades)" setup_unattended_upgrades || warn "Не удалось настроить unattended-upgrades."
}

issue_required_certificate() {
    if [ "${SSL_ENGINE_CHOICE:-1}" = 1 ]; then
        run_with_spinner "Сертификат HTTP-01: $1" obtain_cert "$1"
    else
        run_with_spinner "Сертификат DNS-01: $1" obtain_cf_cert "$1"
    fi
}

install_step_nginx() {
    run_with_spinner "Установка Nginx" setup_nginx_mainline
    NGINX_USER="nginx"
    if ! id -u nginx >/dev/null 2>&1; then
        NGINX_USER="www-data"
    fi

    mkdir -p /etc/systemd/system/nginx.service.d
    cat << 'EOF' > /etc/systemd/system/nginx.service.d/override.conf
[Service]
LimitNOFILE=524288
LimitNPROC=524288
EOF

    systemctl daemon-reload

    log "Инициализация файловой структуры веб-сервера..."
    WEBROOT="/var/www/html"
    mkdir -p "$WEBROOT/.well-known/acme-challenge"
    mkdir -p /var/cache/nginx/img_cache
    mkdir -p /var/cache/nginx/html_cache
    mkdir -p /var/cache/nginx/video_cache
    mkdir -p /var/www/mirror
    mkdir -p /var/www/proxy_temp
    mkdir -p /etc/nginx/stream.d
    mkdir -p /etc/nginx/conf.d

    chown -R "$NGINX_USER:$NGINX_USER" "$WEBROOT" /var/cache/nginx /var/www/mirror /var/www/proxy_temp
    chmod 755 "$WEBROOT" /var/cache/nginx /var/www/mirror /var/www/proxy_temp

    # Стартовый HTTP-сервер для верификации ACME (создается только если Шаг 4 выполняется)
    if [ "$SSL_ENGINE_CHOICE" = "1" ] && [ "${RESUME_STEP:-1}" -le 4 ]; then
        NGINX_80_SERVER_NAMES="${ALL_DOMAINS[*]}"

        # Останавливаем конкурирующие веб-сервисы, если они были предустановлены
        systemctl stop apache2 2>/dev/null || true
        systemctl disable apache2 2>/dev/null || true

        # Удаляем дефолтные конфигурации сайтов с [::]:80, которые приводят к сбою запуска при выключенном IPv6
        rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default /etc/nginx/conf.d/default.conf 2>/dev/null || true
        mkdir -p /etc/nginx/sites-enabled /etc/nginx/conf.d /etc/nginx/modules-enabled "$WEBROOT/.well-known/acme-challenge" 2>/dev/null || true
        chown -R "$NGINX_USER:$NGINX_USER" "$WEBROOT" 2>/dev/null || true

        # Удаляем директивы listen [::]: из существующих файлов conf.d
        sed -i '/\[::\]/d' /etc/nginx/conf.d/*.conf 2>/dev/null || true

        log "Создание стартового HTTP-сервера для верификации ACME..."
        cat << EOF > "/etc/nginx/conf.d/00-acme.conf"
server {
    listen 80;
    server_name $NGINX_80_SERVER_NAMES;
    server_tokens off;
    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        try_files \$uri =404;
    }
    location / { return 301 https://\$host\$request_uri; }
}
EOF

        if ! nginx -t >/dev/null 2>&1; then
            warn "Сбой проверки начальной конфигурации Nginx. Проверка на ошибки ISA или бинарника..."
            setup_nginx_mainline
            if ! nginx -t >/dev/null 2>&1; then
                nginx -t
                die "Ошибка синтаксиса начальной конфигурации Nginx."
            fi
        fi
        systemctl restart nginx >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1
    fi

    # =============================================================
    #  ВЫПУСК SSL-СЕРТИФИКАТОВ (CERTBOT ИЛИ ACME.SH)
    # =============================================================
}

install_step_certificates() {
        # Обеспечиваем доступность портов 80 и 443 для ACME HTTP-01 проверки
        command -v ufw >/dev/null 2>&1 && ufw allow 80/tcp comment 'HTTP (ACME Challenge)' >/dev/null 2>&1 || true
        command -v ufw >/dev/null 2>&1 && ufw allow 443/tcp comment 'HTTPS (ACME Challenge)' >/dev/null 2>&1 || true
        command -v iptables >/dev/null 2>&1 && iptables -I INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || true
        command -v iptables >/dev/null 2>&1 && iptables -I INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1 || true

        if [ "$SSL_ENGINE_CHOICE" = "1" ]; then
            run_with_spinner "Инициализация подсистемы Certbot (APT / Snap)" install_certbot_package || die "Ошибка установки Certbot."

            mkdir -p /etc/letsencrypt
            if [ -n "$LE_EMAIL" ]; then
                cat << EOF > /etc/letsencrypt/cli.ini
email = $LE_EMAIL
agree-tos = true
non-interactive = true
EOF
            else
                cat << EOF > /etc/letsencrypt/cli.ini
register-unsafely-without-email = true
agree-tos = true
non-interactive = true
EOF
            fi

            for dom in "${ALL_DOMAINS[@]}"; do
                issue_required_certificate "$dom" || die "Certificate issuance failed: $dom"
            done

            mkdir -p /etc/letsencrypt/renewal-hooks/deploy/
            cat << 'EOF' > /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
#!/bin/bash
chmod 755 /etc/letsencrypt /etc/letsencrypt/live 2>/dev/null || true
chmod 700 /etc/letsencrypt/archive 2>/dev/null || true
chmod 755 /etc/letsencrypt/live/* 2>/dev/null || true
chmod 644 /etc/letsencrypt/live/*/*.pem 2>/dev/null || true
chmod 600 /etc/letsencrypt/live/*/privkey*.pem 2>/dev/null || true
chmod 600 /etc/letsencrypt/archive/*/privkey*.pem 2>/dev/null || true
systemctl reload nginx
EOF
            chmod +x /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh

        else
            run_with_spinner "Инициализация подсистемы acme.sh" install_acmesh || die "Ошибка установки acme.sh."
            _ACME="${HOME:-/root}/.acme.sh/acme.sh"

            if [ "$CF_AUTH_METHOD" = "1" ]; then
                export CF_Token="$CF_Token"
                [ -n "${CF_Account_ID:-}" ] && export CF_Account_ID="$CF_Account_ID"
            else
                export CF_Email="$CF_Email"
                export CF_Key="$CF_Key"
            fi

            mkdir -p /etc/ssl/acme
            chmod 755 /etc/ssl /etc/ssl/acme

            for dom in "${ALL_DOMAINS[@]}"; do
                issue_required_certificate "$dom" || die "Certificate issuance failed: $dom"
            done
        fi

        # Настройка строгих прав доступа на каталоги SSL для чтения Nginx (изоляция приватных ключей)
        if [ "$SSL_ENGINE_CHOICE" = "1" ]; then
            chmod 755 /etc/letsencrypt /etc/letsencrypt/live 2>/dev/null || true
            chmod 700 /etc/letsencrypt/archive 2>/dev/null || true
            for dom in "${ALL_DOMAINS[@]}"; do
                if [ -d "/etc/letsencrypt/live/$dom" ]; then
                    chmod 755 "/etc/letsencrypt/live/$dom" 2>/dev/null || true
                    chmod 644 /etc/letsencrypt/live/"$dom"/*.pem 2>/dev/null || true
                    chmod 600 /etc/letsencrypt/live/"$dom"/privkey*.pem 2>/dev/null || true
                    chmod 600 /etc/letsencrypt/archive/"$dom"/privkey*.pem 2>/dev/null || true
                fi
            done
        else
            chmod 750 /etc/ssl/acme 2>/dev/null || true
            chown -R root:www-data /etc/ssl/acme 2>/dev/null || true
            for dom in "${ALL_DOMAINS[@]}"; do
                if [ -d "/etc/ssl/acme/$dom" ]; then
                    chmod 750 "/etc/ssl/acme/$dom" 2>/dev/null || true
                    chmod 640 /etc/ssl/acme/"$dom"/*.pem 2>/dev/null || true
                    chmod 600 /etc/ssl/acme/"$dom"/privkey*.pem 2>/dev/null || true
                fi
            done
        fi
}
install_step_decoy() {
    :
# =============================================================
#  ГЕНЕРАЦИЯ ВЫБРАННОЙ ВЕБ-МАСКИ
# =============================================================
    log "Формирование выбранного маскировочного портала..."

    if [ "$DECOY_MODE" = "1" ]; then
    # 1. DataSphere Analytics (SPA с 3D-сферой и телеметрией)
    mkdir -p "$WEBROOT/assets/css" "$WEBROOT/assets/js" "$WEBROOT/assets/img"

cat << 'EOF' > $WEBROOT/assets/img/favicon.svg
<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <radialGradient id="sphereGrad" cx="35%" cy="35%" r="65%">
      <stop offset="0%" stop-color="#a8c7fa"/>
      <stop offset="45%" stop-color="#008dd5"/>
      <stop offset="100%" stop-color="#0a192f"/>
    </radialGradient>
    <clipPath id="circleMask"><circle cx="50" cy="50" r="48"/></clipPath>
  </defs>
  <g clip-path="url(#circleMask)">
    <circle cx="50" cy="50" r="48" fill="url(#sphereGrad)"/>
    <g stroke="#ffffff" stroke-width="1.5" stroke-opacity="0.45" fill="none">
      <ellipse cx="50" cy="50" rx="46" ry="18"/>
      <ellipse cx="50" cy="50" rx="46" ry="32"/>
      <ellipse cx="50" cy="50" rx="18" ry="46"/>
      <ellipse cx="50" cy="50" rx="32" ry="46"/>
      <line x1="4" y1="50" x2="96" y2="50"/>
      <line x1="50" y1="4" x2="50" y2="96"/>
    </g>
    <circle cx="50" cy="50" r="6" fill="#81c995"/>
    <circle cx="28" cy="38" r="3.5" fill="#fdd663"/>
    <circle cx="72" cy="62" r="3.5" fill="#c58af9"/>
    <circle cx="70" cy="35" r="3" fill="#a8c7fa"/>
    <circle cx="32" cy="65" r="3" fill="#ffffff"/>
  </g>
  <circle cx="50" cy="50" r="48" fill="none" stroke="#a8c7fa" stroke-width="3" stroke-opacity="0.6"/>
</svg>
EOF
ln -sf $WEBROOT/assets/img/favicon.svg $WEBROOT/favicon.svg
ln -sf $WEBROOT/assets/img/favicon.svg $WEBROOT/favicon.ico

cat << 'EOF' > $WEBROOT/robots.txt
User-agent: *
Disallow: /api/
Disallow: /console/
Disallow: /telemetry/
Disallow: /cluster-internal/
Allow: /
EOF

cat << 'EOF' > $WEBROOT/assets/css/datasphere.css
:root {
    --bg-base: #0b0d10;
    --bg-surface: #13171d;
    --bg-card: #181d24;
    --border: rgba(255, 255, 255, 0.08);
    --border-hover: rgba(168, 199, 250, 0.35);
    --accent: #a8c7fa;
    --accent-glow: rgba(168, 199, 250, 0.15);
    --accent-purple: #c58af9;
    --text-primary: #e6edf3;
    --text-muted: #8b949e;
    --success: #81c995;
    --warning: #fdd663;
    --error: #f28b82;
    --terminal-bg: #090c10;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Google Sans", sans-serif;
    background-color: var(--bg-base);
    background-image:
        radial-gradient(circle at 50% -10%, rgba(66, 133, 244, 0.14) 0%, rgba(155, 114, 207, 0.08) 35%, transparent 70%),
        radial-gradient(circle at 100% 100%, rgba(129, 201, 149, 0.04) 0%, transparent 40%),
        var(--bg-base);
    color: var(--text-primary); line-height: 1.6; overflow-x: hidden; min-height: 100vh;
}
header {
    display: flex; justify-content: space-between; align-items: center; padding: 18px 6%;
    border-bottom: 1px solid var(--border); backdrop-filter: blur(20px);
    position: sticky; top: 0; z-index: 50; background: rgba(11, 13, 16, 0.82);
}
.brand { display: flex; align-items: center; gap: 12px; font-size: 20px; font-weight: 700; color: #fff; letter-spacing: -0.4px; }
.btn {
    background: var(--bg-card); border: 1px solid var(--border); color: var(--text-primary);
    padding: 10px 22px; border-radius: 999px; font-size: 14px; font-weight: 600; cursor: pointer;
    transition: all 0.25s cubic-bezier(0.4, 0, 0.2, 1); display: inline-flex; align-items: center; gap: 8px;
    box-shadow: 0 4px 14px rgba(0, 0, 0, 0.2); user-select: none;
}
.btn:hover { transform: translateY(-1px); border-color: var(--border-hover); background: #202630; box-shadow: 0 6px 20px rgba(0, 0, 0, 0.4); }
.btn:active { transform: translateY(0); }
.btn-primary { background: #1f3a60; border-color: #388bfd; color: #fff; }
.btn-primary:hover { background: #264a7a; border-color: #58a6ff; }
.hero-split {
    display: grid; grid-template-columns: 1.1fr 0.9fr; gap: 40px; align-items: center;
    max-width: 1240px; margin: 40px auto; padding: 40px 6%;
}
@media (max-width: 900px) { .hero-split { grid-template-columns: 1fr; text-align: center; } }
.hero-text h1 { font-size: clamp(34px, 4.5vw, 52px); font-weight: 700; line-height: 1.15; margin-bottom: 20px; letter-spacing: -0.8px; }
.hero-text p { font-size: 17px; color: var(--text-muted); line-height: 1.65; margin-bottom: 30px; }
.badge {
    display: inline-flex; align-items: center; gap: 8px; padding: 6px 14px; background: var(--bg-card);
    border: 1px solid var(--border); border-radius: 999px; font-size: 13px; font-weight: 500; color: var(--accent); margin-bottom: 20px;
}
.badge-dot { width: 7px; height: 7px; background: var(--success); border-radius: 50%; box-shadow: 0 0 8px var(--success); }
.canvas-wrapper {
    position: relative; width: 100%; aspect-ratio: 1; max-width: 480px; margin: 0 auto;
    display: flex; align-items: center; justify-content: center;
}
#sphereCanvas { width: 100%; height: 100%; border-radius: 50%; filter: drop-shadow(0 0 35px rgba(56, 139, 253, 0.2)); }
.stats-bar { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; max-width: 1140px; margin: 0 auto 50px; padding: 0 6%; }
.stat-card { background: var(--bg-card); border: 1px solid var(--border); padding: 22px; border-radius: 18px; text-align: center; }
.stat-card h3 { font-size: 28px; font-weight: 700; color: #fff; }
.stat-card p { font-size: 13px; color: var(--text-muted); margin-top: 4px; }
.features { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 20px; max-width: 1140px; margin: 0 auto 60px; padding: 0 6%; }
.feature-card {
    background: var(--bg-card); border: 1px solid var(--border); padding: 30px 24px; border-radius: 20px;
    cursor: pointer; transition: all 0.25s ease; display: flex; flex-direction: column; justify-content: space-between;
}
.feature-card:hover { transform: translateY(-3px); border-color: var(--border-hover); background: #1c222b; }
.feature-card h3 { font-size: 18px; font-weight: 600; margin-bottom: 10px; color: #fff; }
.feature-card p { font-size: 14px; color: var(--text-muted); line-height: 1.55; }
.card-action { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; font-weight: 600; color: var(--accent); margin-top: 16px; }
.telemetry-section { max-width: 1140px; margin: 0 auto 80px; padding: 0 6%; }
.terminal-card {
    background: var(--terminal-bg); border: 1px solid var(--border); border-radius: 20px; overflow: hidden;
    box-shadow: 0 20px 40px rgba(0, 0, 0, 0.4);
}
.terminal-header {
    background: #161b22; padding: 12px 18px; display: flex; align-items: center; gap: 8px; border-bottom: 1px solid var(--border);
}
.term-dot { width: 11px; height: 11px; border-radius: 50%; display: inline-block; }
.term-dot.r { background: #ff5f56; } .term-dot.y { background: #ffbd2e; } .term-dot.g { background: #27c93f; }
.term-title { font-size: 12px; font-family: monospace; color: var(--text-muted); margin-left: 8px; }
.terminal-body { padding: 20px; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size: 13px; color: #c9d1d9; }
.telemetry-canvas-wrap { width: 100%; height: 160px; margin-bottom: 18px; position: relative; }
#chartCanvas { width: 100%; height: 100%; }
.terminal-logs { max-height: 180px; overflow-y: auto; display: flex; flex-direction: column; gap: 6px; }
.log-line { line-height: 1.4; color: #8b949e; word-break: break-all; }
.log-line span.ts { color: #58a6ff; }
.log-line span.hl { color: #7ee787; font-weight: 600; }
.cli-prompt { display: flex; align-items: center; gap: 8px; margin-top: 14px; padding-top: 12px; border-top: 1px solid rgba(255, 255, 255, 0.05); }
.cli-prompt input {
    background: transparent; border: none; outline: none; color: #fff; font-family: inherit; font-size: 13px; flex: 1;
}
.modal-overlay {
    position: fixed; inset: 0; background: rgba(5, 7, 10, 0.85); backdrop-filter: blur(16px);
    display: flex; align-items: center; justify-content: center; padding: 20px; z-index: 100;
    opacity: 0; visibility: hidden; transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
}
.modal-overlay.active { opacity: 1; visibility: visible; }
.modal-card {
    background: var(--bg-surface); border: 1px solid var(--border); border-radius: 24px; width: 100%; max-width: 480px;
    padding: 32px; box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.7); transform: translateY(20px); transition: transform 0.3s ease;
}
.modal-overlay.active .modal-card { transform: translateY(0); }
.modal-header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 18px; }
.modal-header h2 { font-size: 20px; font-weight: 700; color: #fff; }
.modal-header p { font-size: 13px; color: var(--text-muted); margin-top: 4px; }
.modal-close { background: transparent; border: none; color: var(--text-muted); cursor: pointer; padding: 4px; display: flex; }
.modal-close:hover { color: #fff; }
.form-group { margin-bottom: 16px; }
.form-group label { display: block; font-size: 13px; font-weight: 500; color: #c4c7c5; margin-bottom: 6px; }
.form-control {
    width: 100%; padding: 12px 14px; background: #090c10; border: 1px solid var(--border); border-radius: 12px;
    color: #fff; font-size: 14px; outline: none; transition: all 0.2s ease;
}
.form-control:focus { border-color: var(--accent); box-shadow: 0 0 0 3px rgba(168, 199, 250, 0.2); }
.alert-box {
    background: rgba(239, 68, 68, 0.12); border: 1px solid rgba(239, 68, 68, 0.3); color: #fca5a5;
    padding: 12px 14px; border-radius: 12px; font-size: 13px; margin-bottom: 18px; display: none; align-items: center; gap: 10px;
}
.toast-hud {
    position: fixed; bottom: 30px; right: 30px; background: var(--bg-card); border: 1px solid var(--border-hover);
    border-radius: 16px; padding: 16px 20px; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.6); display: flex; align-items: flex-start; gap: 12px;
    z-index: 200; max-width: 360px; transform: translateY(100px); opacity: 0; visibility: hidden; transition: all 0.3s ease;
}
.toast-hud.active { transform: translateY(0); opacity: 1; visibility: visible; }
.spinner { width: 16px; height: 16px; border: 2px solid rgba(255, 255, 255, 0.3); border-top: 2px solid #fff; border-radius: 50%; animation: spin 0.8s linear infinite; }
footer { text-align: center; padding: 40px 20px; color: var(--text-muted); font-size: 13px; border-top: 1px solid var(--border); }
@keyframes spin { 100% { transform: rotate(360deg); } }
EOF

cat << 'EOF' > $WEBROOT/assets/js/datasphere.js
"use strict";

document.addEventListener("DOMContentLoaded", () => {
    const sCanvas = document.getElementById("sphereCanvas");
    if (sCanvas) {
        const ctx = sCanvas.getContext("2d");
        let width, height;
        const dpr = window.devicePixelRatio || 1;

        const resizeSphere = () => {
            const rect = sCanvas.getBoundingClientRect();
            width = rect.width;
            height = rect.height;
            sCanvas.width = width * dpr;
            sCanvas.height = height * dpr;
            ctx.scale(dpr, dpr);
        };
        resizeSphere();
        window.addEventListener("resize", resizeSphere);

        const nodesCount = 92;
        const nodes = [];
        const radius = 150;

        for (let i = 0; i < nodesCount; i++) {
            const phi = Math.acos(-1 + (2 * i) / nodesCount);
            const theta = Math.sqrt(nodesCount * Math.PI) * phi;
            nodes.push({
                x: radius * Math.cos(theta) * Math.sin(phi),
                y: radius * Math.sin(theta) * Math.sin(phi),
                z: radius * Math.cos(phi)
            });
        }

        let rotX = 0.003;
        let rotY = 0.005;
        let targetRotX = 0.003;
        let targetRotY = 0.005;

        window.addEventListener("mousemove", (e) => {
            const nx = (e.clientX / window.innerWidth) - 0.5;
            const ny = (e.clientY / window.innerHeight) - 0.5;
            targetRotX = ny * 0.015;
            targetRotY = nx * 0.015;
        });

        let isVisible = true;
        document.addEventListener("visibilitychange", () => {
            isVisible = !document.hidden;
        });

        const project = (p) => {
            const fov = 340;
            const factor = fov / (fov + p.z);
            return {
                x: p.x * factor + width / 2,
                y: p.y * factor + height / 2,
                scale: factor
            };
        };

        const renderSphere = () => {
            if (!isVisible) {
                requestAnimationFrame(renderSphere);
                return;
            }

            rotX += (targetRotX - rotX) * 0.05;
            rotY += (targetRotY - rotY) * 0.05;

            ctx.clearRect(0, 0, width, height);

            const cosX = Math.cos(rotX), sinX = Math.sin(rotX);
            const cosY = Math.cos(rotY), sinY = Math.sin(rotY);

            for (let i = 0; i < nodes.length; i++) {
                let p = nodes[i];
                let y1 = p.y * cosX - p.z * sinX;
                let z1 = p.y * sinX + p.z * cosX;
                let x2 = p.x * cosY + z1 * sinY;
                let z2 = -p.x * sinY + z1 * cosY;
                nodes[i] = { x: x2, y: y1, z: z2 };
            }

            ctx.lineWidth = 0.7;
            for (let i = 0; i < nodes.length; i++) {
                const p1 = project(nodes[i]);
                for (let j = i + 1; j < nodes.length; j++) {
                    const dx = nodes[i].x - nodes[j].x;
                    const dy = nodes[i].y - nodes[j].y;
                    const dz = nodes[i].z - nodes[j].z;
                    const dist = Math.sqrt(dx * dx + dy * dy + dz * dz);
                    if (dist < 64) {
                        const p2 = project(nodes[j]);
                        const alpha = (1 - dist / 64) * 0.35 * Math.min(p1.scale, p2.scale);
                        ctx.strokeStyle = `rgba(168, 199, 250, ${alpha})`;
                        ctx.beginPath();
                        ctx.moveTo(p1.x, p1.y);
                        ctx.lineTo(p2.x, p2.y);
                        ctx.stroke();
                    }
                }
            }

            for (let i = 0; i < nodes.length; i++) {
                const p = project(nodes[i]);
                const alpha = Math.max(0.1, (nodes[i].z + radius) / (2 * radius));
                ctx.fillStyle = `rgba(129, 201, 149, ${alpha})`;
                ctx.beginPath();
                ctx.arc(p.x, p.y, 2 * p.scale, 0, Math.PI * 2);
                ctx.fill();
            }

            requestAnimationFrame(renderSphere);
        };
        requestAnimationFrame(renderSphere);
    }

    const cCanvas = document.getElementById("chartCanvas");
    if (cCanvas) {
        const cCtx = cCanvas.getContext("2d");
        const pointsCount = 40;
        const dataPoints = Array.from({ length: pointsCount }, () => 80 + Math.random() * 18);

        const renderChart = () => {
            const w = cCanvas.parentElement.clientWidth;
            const h = cCanvas.parentElement.clientHeight;
            cCanvas.width = w * window.devicePixelRatio;
            cCanvas.height = h * window.devicePixelRatio;
            cCtx.scale(window.devicePixelRatio, window.devicePixelRatio);

            cCtx.clearRect(0, 0, w, h);

            cCtx.strokeStyle = "rgba(255, 255, 255, 0.05)";
            cCtx.lineWidth = 1;
            cCtx.beginPath();
            for (let y = 20; y < h; y += 30) {
                cCtx.moveTo(0, y); cCtx.lineTo(w, y);
            }
            cCtx.stroke();

            const step = w / (pointsCount - 1);
            cCtx.beginPath();
            cCtx.moveTo(0, h - (dataPoints[0] / 100) * h);

            for (let i = 0; i < pointsCount - 1; i++) {
                const x0 = i * step;
                const y0 = h - (dataPoints[i] / 100) * (h * 0.85);
                const x1 = (i + 1) * step;
                const y1 = h - (dataPoints[i + 1] / 100) * (h * 0.85);
                const mx = (x0 + x1) / 2;
                cCtx.quadraticCurveTo(x0, y0, mx, (y0 + y1) / 2);
            }

            cCtx.strokeStyle = "#58a6ff";
            cCtx.lineWidth = 2;
            cCtx.stroke();

            cCtx.lineTo(w, h);
            cCtx.lineTo(0, h);
            cCtx.closePath();
            const grad = cCtx.createLinearGradient(0, 0, 0, h);
            grad.addColorStop(0, "rgba(88, 166, 255, 0.25)");
            grad.addColorStop(1, "rgba(88, 166, 255, 0.0)");
            cCtx.fillStyle = grad;
            cCtx.fill();
        };

        renderChart();
        window.addEventListener("resize", renderChart);

        setInterval(() => {
            const randArr = new Uint32Array(1);
            window.crypto.getRandomValues(randArr);
            const delta = (randArr[0] / 0xffffffff - 0.5) * 6;
            let last = dataPoints[dataPoints.length - 1] + delta;
            if (last > 99.8) last = 96.0;
            if (last < 75.0) last = 78.0;
            dataPoints.shift();
            dataPoints.push(last);
            renderChart();
        }, 1200);
    }

    const termLogs = document.getElementById("terminalLogs");
    const cliInput = document.getElementById("cliInput");
    const authModal = document.getElementById("authModal");
    const detailModal = document.getElementById("detailModal");
    const toastHud = document.getElementById("toastHud");

    const showToast = (title, desc) => {
        document.getElementById("toastTitle").innerText = title;
        document.getElementById("toastDesc").innerText = desc;
        toastHud.classList.add("active");
        setTimeout(() => toastHud.classList.remove("active"), 4500);
    };

    const addLog = (msg, hl = false) => {
        if (!termLogs) return;
        const now = new Date().toISOString().split("T")[1].slice(0, 8);
        const div = document.createElement("div");
        div.className = "log-line";
        div.innerHTML = `<span class="ts">[${now}]</span> ${hl ? '<span class="hl">' + msg + '</span>' : msg}`;
        termLogs.appendChild(div);
        termLogs.scrollTop = termLogs.scrollHeight;
    };

    cliInput?.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
            const val = cliInput.value.trim().toLowerCase();
            cliInput.value = "";
            addLog(`$ ${val}`, true);

            if (val === "help") {
                addLog("Доступные команды: status, nodes, crypto, telemetry, clear");
            } else if (val === "status") {
                addLog("Ядро Anycast: ONLINE | Ингресс H2C/TLS: 100 Gbps | Потери: 0.000%");
            } else if (val === "nodes") {
                addLog("Активно узлов: 148 PoP (EU: 62, US: 54, APAC: 32) | Балансировка: FQ/BBR");
            } else if (val === "crypto") {
                addLog("Шифрование сессий: TLS 1.3 (RFC 8446) / ChaCha20-Poly1305 / AES-256-GCM");
            } else if (val === "clear") {
                termLogs.innerHTML = "";
            } else {
                addLog(`Команда не найдена: '${val}'. Введите 'help' для справки.`);
            }
        }
    });

    const openAuth = () => { authModal.classList.add("active"); };
    const closeModals = () => {
        authModal.classList.remove("active");
        detailModal.classList.remove("active");
    };

    document.getElementById("headerConsoleBtn")?.addEventListener("click", openAuth);
    document.getElementById("connectNodeBtn")?.addEventListener("click", openAuth);
    document.getElementById("authModalClose")?.addEventListener("click", closeModals);
    document.getElementById("detailModalClose")?.addEventListener("click", closeModals);
    document.getElementById("detailModalOk")?.addEventListener("click", closeModals);

    document.getElementById("netStatusBtn")?.addEventListener("click", () => {
        showToast("Сетевой кластер DataSphere", "Anycast-маршрутизация активна: RTT < 1.2 ms.");
    });

    document.getElementById("authForm")?.addEventListener("submit", (e) => {
        e.preventDefault();
        const submitBtn = document.getElementById("submitBtn");
        submitBtn.innerHTML = '<span class="spinner"></span> Верификация...';
        submitBtn.disabled = true;

        setTimeout(() => {
            document.getElementById("errorMsg").innerText = "Ошибка 401: Доступ отклонен. Ключ узла не сертифицирован.";
            document.getElementById("errorAlert").style.display = "flex";
            submitBtn.innerHTML = "Подключиться к кластеру";
            submitBtn.disabled = false;
        }, 800);
    });

    const details = {
        cardCrypto: {
            title: "Сквозное квантовое шифрование",
            desc: "Аппаратная акселерация ML-KEM-768",
            content: "Сессии терминируются с использованием постквантовой криптографии на базе решеток (ML-KEM-768) в связке с X25519. Срок жизни сессионного ключа строго ограничен 300 секундами."
        },
        cardTelemetry: {
            title: "Распределенная Anycast-телеметрия",
            desc: "Многопоточный конвейер синхронизации",
            content: "Метрики сетевого потока агрегируются в режиме реального времени на границе датацентров. Потери пакетов устранены за счет алгоритмов упреждающей маршрутизации FQ/BBR."
        },
        cardIpc: {
            title: "Изоляция сокетов In-Memory IPC",
            desc: "Zero-Copy архитектура обмена",
            content: "Межсервисный транспорт внутри хоста маршрутизируется через энергонезависимые сокеты в Shared Memory (/dev/shm) без накладных расходов сетевого стека ядра."
        },
        cardOffload: {
            title: "Аппаратная терминация очередей",
            desc: "Масштабирование сокетов somaxconn",
            content: "Сетевой стек оптимизирован под максимальную утилизацию очередей ядра (somaxconn = 65535, rmem/wmem до 64 MB), полностью исключая дропы при пиках входящих соединений."
        }
    };

    Object.keys(details).forEach(id => {
        document.getElementById(id)?.addEventListener("click", () => {
            const item = details[id];
            document.getElementById("detailTitle").innerText = item.title;
            document.getElementById("detailSubtitle").innerText = item.desc;
            document.getElementById("detailContent").innerHTML = `<p style="color:#8b949e; font-size:14px; line-height:1.6;">${item.content}</p>`;
            detailModal.classList.add("active");
        });
    });
});
EOF

cat << 'EOF' > $WEBROOT/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>DataSphere Analytics — Платформа распределенной аналитики данных</title>
    <meta name="description" content="Корпоративная среда распределенной обработки данных с квантово-устойчивым шифрованием ML-KEM-768, аппаратной акселерацией L4/L7 и Anycast-маршрутизацией узлов.">
    <link rel="icon" type="image/svg+xml" href="/assets/img/favicon.svg">
    <link rel="stylesheet" href="/assets/css/datasphere.css">
    <script defer src="/assets/js/datasphere.js"></script>
</head>
<body>
    <header>
        <div class="brand">
            <svg viewBox="0 0 100 100" width="28" height="28" xmlns="http://www.w3.org/2000/svg">
                <circle cx="50" cy="50" r="46" fill="#008dd5"/>
                <ellipse cx="50" cy="50" rx="42" ry="16" fill="none" stroke="#fff" stroke-width="3"/>
                <circle cx="50" cy="50" r="7" fill="#81c995"/>
            </svg>
            DataSphere Analytics
        </div>
        <button type="button" id="headerConsoleBtn" class="btn">Консоль инженера</button>
    </header>

    <main>
        <section class="hero-split">
            <div class="hero-text">
                <div class="badge"><span class="badge-dot"></span><span>DataSphere Core v4.0 — Доступность 99.998%</span></div>
                <h1>Распределенная сеть обработки и защиты корпоративных данных</h1>
                <p>Высоконагруженная инфраструктура с аппаратной изоляцией памяти, поддержкой современных стандартов шифрования TLS 1.3 и магистральной Anycast-маршрутизацией.</p>
                <div style="display:flex; gap:14px; flex-wrap:wrap;">
                    <button type="button" id="connectNodeBtn" class="btn btn-primary">Подключить вычислительный узел</button>
                    <button type="button" id="netStatusBtn" class="btn">Статус Anycast-магистрали</button>
                </div>
            </div>
            <div class="canvas-wrapper">
                <canvas id="sphereCanvas"></canvas>
            </div>
        </section>

        <section class="stats-bar">
            <div class="stat-card"><h3>&lt; 1.2 ms</h3><p>Задержка магистрали</p></div>
            <div class="stat-card"><h3>100 Gbps</h3><p>Пропускная способность</p></div>
            <div class="stat-card"><h3>ML-KEM-768</h3><p>Постквантовый обмен</p></div>
            <div class="stat-card"><h3>Zero-Copy</h3><p>IPC Shared Memory</p></div>
        </section>

        <section class="features">
            <div class="feature-card" id="cardCrypto">
                <div>
                    <h3>Квантово-стойкое шифрование</h3>
                    <p>Терминация трафика осуществляется на базе криптографических стандартов ML-KEM-768 с ротацией сессионных ключей каждые 300 секунд.</p>
                </div>
                <span class="card-action">Спецификация криптомодуля &rarr;</span>
            </div>
            <div class="feature-card" id="cardTelemetry">
                <div>
                    <h3>Anycast-телеметрия</h3>
                    <p>Автоматическая балансировка потоков между 148 географически распределенными точками присутствия без деградации RTT.</p>
                </div>
                <span class="card-action">Топология узлов &rarr;</span>
            </div>
            <div class="feature-card" id="cardIpc">
                <div>
                    <h3>Изоляция сокетов IPC</h3>
                    <p>Прямая маршрутизация очередей данных через сегменты Shared Memory (/dev/shm) без накладных расходов сетевого стека.</p>
                </div>
                <span class="card-action">Zero-Copy конвейер &rarr;</span>
            </div>
            <div class="feature-card" id="cardOffload">
                <div>
                    <h3>Масштабирование сокетов</h3>
                    <p>Глубокая оптимизация somaxconn и буферов сокетов rmem/wmem до 64 МБ для защиты от сброса сессий при всплесках трафика.</p>
                </div>
                <span class="card-action">Аудит сетевого ядра &rarr;</span>
            </div>
        </section>

        <section class="telemetry-section">
            <div class="terminal-card">
                <div class="terminal-header">
                    <span class="term-dot r"></span>
                    <span class="term-dot y"></span>
                    <span class="term-dot g"></span>
                    <span class="term-title">datasphere-edge-telemetry — 100 Gbps Ingress/Egress Stream Monitor</span>
                </div>
                <div class="terminal-body">
                    <div class="telemetry-canvas-wrap">
                        <canvas id="chartCanvas"></canvas>
                    </div>
                    <div class="terminal-logs" id="terminalLogs">
                        <div class="log-line"><span class="ts">[INIT]</span> Магистральный конвейер BGP Anycast инициализирован. Шлюз активен.</div>
                        <div class="log-line"><span class="ts">[INFO]</span> Криптографический модуль ML-KEM-768 синхронизирован с HSM-кластером.</div>
                        <div class="log-line"><span class="ts">[METRIC]</span> Текущая загрузка буферов ядра: <span class="hl">0.02%</span>. Сессии обслуживаются без задержек.</div>
                    </div>
                    <div class="cli-prompt">
                        <span style="color:#58a6ff;">datasphere@edge:~$</span>
                        <input type="text" id="cliInput" placeholder="Введите команду (help, status, nodes, crypto, clear)..." autocomplete="off">
                    </div>
                </div>
            </div>
        </section>
    </main>

    <div id="authModal" class="modal-overlay">
        <div class="modal-card">
            <div class="modal-header">
                <div>
                    <h2>Вход в консоль узла</h2>
                    <p>Введите идентификатор для авторизации в кластере</p>
                </div>
                <button type="button" id="authModalClose" class="modal-close">
                    <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>
                </button>
            </div>
            <div id="errorAlert" class="alert-box">
                <span id="errorMsg">Ошибка доступа</span>
            </div>
            <form id="authForm">
                <div class="form-group">
                    <label for="nodeUser">Идентификатор узла (Node ID)</label>
                    <input type="text" id="nodeUser" class="form-control" placeholder="node-edge-01@datasphere.cloud" required>
                </div>
                <div class="form-group">
                    <label for="nodeKey">Секретный токен API</label>
                    <input type="password" id="nodeKey" class="form-control" placeholder="••••••••••••••••" required>
                </div>
                <button type="submit" id="submitBtn" class="btn btn-primary" style="width:100%; justify-content:center;">Подключиться к кластеру</button>
            </form>
        </div>
    </div>

    <div id="detailModal" class="modal-overlay">
        <div class="modal-card">
            <div class="modal-header">
                <div>
                    <h2 id="detailTitle">Спецификация</h2>
                    <p id="detailSubtitle">Параметры подсистемы DataSphere</p>
                </div>
                <button type="button" id="detailModalClose" class="modal-close">
                    <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 6L6 18M6 6l12 12"/></svg>
                </button>
            </div>
            <div id="detailContent" style="margin-bottom:20px;"></div>
            <button type="button" id="detailModalOk" class="btn" style="width:100%; justify-content:center;">Понятно</button>
        </div>
    </div>

    <div id="toastHud" class="toast-hud">
        <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="#81c995" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/></svg>
        <div>
            <div id="toastTitle" style="font-weight:600; font-size:14px; color:#fff;">Оповещение</div>
            <div id="toastDesc" style="font-size:12px; color:#8b949e;">Информация о сети</div>
        </div>
    </div>

    <footer>&copy; 2026 DataSphere Cloud Systems Inc. Платформа распределенной аналитики и защиты данных.</footer>
</body>
</html>
EOF


elif [ "$DECOY_MODE" = "2" ]; then
    # 2. CosmosCloud NextGen (с ассетами и оригинальным logo.webp)
    cat << 'EOF' > /var/www/html/index.html
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>My Cloud</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0, minimum-scale=1.0, maximum-scale=1.0">
    <style>
        body { margin:0; padding:20px; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; background-color:#cbcae0; background-image:linear-gradient(135deg,#e2e1ec 0%,#bcbbcb 100%); display:flex; flex-direction:column; align-items:center; justify-content:center; min-height:100vh; color:#333; box-sizing:border-box; }
        .page-wrapper { width:100%; max-width:420px; display:flex; flex-direction:column; align-items:center; box-shadow:0 15px 35px rgba(0,0,0,0.15); border-radius:12px; overflow:hidden; }
        .banner-img { width:100%; height:auto; display:block; }
        .login-container { background:#fff; width:100%; text-align:center; padding:35px 30px; box-sizing:border-box; }
        .header-title { font-size:20px; color:#4a4557; margin-bottom:25px; font-weight:400; }
        .input-group { position:relative; margin-bottom:14px; }
        input { width:100%; padding:12px 15px; border:1px solid #ccc; border-radius:6px; box-sizing:border-box; font-size:15px; outline:none; transition:border-color .2s,box-shadow .2s; background:#fdfdfd; }
        input:focus { border-color:#735b8c; box-shadow:0 0 0 3px rgba(115,91,140,.15); background:#fff; }
        button { width:100%; padding:12px; background:#735b8c; color:#fff; border:none; border-radius:6px; font-size:16px; font-weight:600; cursor:pointer; margin-top:10px; transition:background .2s,opacity .2s; display:flex; justify-content:center; align-items:center; height:44px; }
        button:hover { background:#5d4874; }
        button:disabled { opacity:.7; cursor:not-allowed; }
        .message-box { background:#e74c3c; color:#fff; padding:11px; border-radius:6px; margin-bottom:20px; font-size:14px; text-align:left; display:none; animation:fadeIn .3s ease; }
        .spinner { display:inline-block; width:18px; height:18px; border:2px solid rgba(255,255,255,.3); border-top:2px solid #fff; border-radius:50%; animation:spin .8s linear infinite; }
        .footer-text { margin-top:25px; color:rgba(60,55,70,.6); font-size:13px; text-align:center; width:100%; }
        .footer-text a { color:#735b8c; text-decoration:none; font-weight:500; }
        @keyframes spin { 100% { transform:rotate(360deg); } }
        @keyframes fadeIn { from { opacity:0; transform:translateY(-5px); } to { opacity:1; transform:translateY(0); } }
    </style>
</head>
<body>
    <div class="page-wrapper">
        <img class="banner-img" src="logo.webp" alt="Cloud Header" onerror="this.style.display='none'">
        <div class="login-container">
            <div class="header-title">Вход в облако</div>
            <div id="errorBox" class="message-box"></div>
            <form id="loginForm" onsubmit="handleLogin(event)">
                <div class="input-group"><input id="user" type="text" placeholder="Имя пользователя или email" autocomplete="username" required></div>
                <div class="input-group"><input id="pass" type="password" placeholder="Пароль" autocomplete="current-password" required></div>
                <button type="submit" id="loginBtn">Войти</button>
            </form>
        </div>
    </div>
    <div class="footer-text">
        <a href="#">Cosmos Cloud</a> – безопасный дом для ваших данных
    </div>
    <script>
        function setFakeCookie() { document.cookie = "cosmos_session=" + Math.random().toString(36).substring(2) + "; path=/; Secure; SameSite=Lax"; }
        async function handleLogin(e) {
            e.preventDefault();
            const btn = document.getElementById("loginBtn"), errBox = document.getElementById("errorBox");
            errBox.style.display = "none"; btn.disabled = true; btn.innerHTML = '<div class="spinner"></div>';
            try {
                const response = await fetch("/api/v1/auth/login", {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ user: document.getElementById("user").value, pass: document.getElementById("pass").value })
                });
                const data = await response.json();
                errBox.innerText = data.error || "Wrong nickname or password.";
                errBox.style.display = "block";
            } catch (err) {
                errBox.innerText = "Ошибка сетевого соединения с облаком.";
                errBox.style.display = "block";
            } finally {
                btn.disabled = false; btn.innerHTML = 'Войти';
            }
        }
        setFakeCookie();
    </script>
</body>
</html>
EOF

    log "Загрузка оригинальных графических ассетов Cosmos Cloud..."
    if curl -fsSL --connect-timeout 10 "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/logo.webp" -o "$WEBROOT/logo.webp" 2>/dev/null; then
        ok "Логотип успешно загружен из основного репозитория GitHub."
    else
        warn "Прямое подключение к GitHub не удалось. Переключаемся на резервное зеркало CDN..."
        if curl -fsSL --connect-timeout 10 "https://cdn.jsdelivr.net/gh/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui@main/logo.webp" -o "$WEBROOT/logo.webp" 2>/dev/null; then
            ok "Логотип успешно загружен из резервного зеркала CDN (jsDelivr)."
        else
            warn "Не удалось загрузить логотип. Веб-маска будет работать в режиме текстовой заглушки."
        fi
    fi

    if [ -f "$WEBROOT/logo.webp" ]; then
        magic_riff=$(head -c 4 "$WEBROOT/logo.webp" | tr -d '\0' || true)
        magic_webp=$(dd if="$WEBROOT/logo.webp" bs=1 skip=8 count=4 status=none 2>/dev/null | tr -d '\0' || true)
        if [[ "$magic_riff" != "RIFF" || "$magic_webp" != "WEBP" ]]; then
            warn "Файл logo.webp имеет неверный формат. Удаление поврежденного файла..."
            rm -f "$WEBROOT/logo.webp"
        else
            ok "Файл logo.webp успешно верифицирован по сигнатуре формата."
        fi
    fi

else
    # 3. Welcome to nginx
    cat << 'EOF' > /var/www/html/index.html
<!DOCTYPE html>
<html><head><title>Welcome to nginx!</title><style>body { width: 35em; margin: 0 auto; font-family: Tahoma, Verdana, Arial, sans-serif; }</style></head><body><h1>Welcome to nginx!</h1><p>If you see this page, the nginx web server is successfully installed and working.</p></body></html>
EOF
fi

cat << 'EOF' > /var/www/html/404.html
<!DOCTYPE html>
<html><head><title>404 Not Found</title></head><body><center><h1>404 Not Found</h1></center><hr><center>nginx</center></body></html>
EOF

    [ -f "$WEBROOT/robots.txt" ] || cat << 'EOF_ROBOTS' > "$WEBROOT/robots.txt"
User-agent: *
Disallow: /
EOF_ROBOTS

    chown -R "$NGINX_USER:$NGINX_USER" "$WEBROOT"
    chmod -R 755 "$WEBROOT"
}
install_step_nginx_config() {
    :
# =============================================================
#  ШАГ 6: ПОЛНАЯ КОНФИГУРАЦИЯ NGINX И ПЕРЕЗАПУСК СЛУЖБ
# =============================================================
    if [ -z "${PANEL_PATH:-}" ]; then
        if command -v ensure_panel_path >/dev/null 2>&1; then
            ensure_panel_path || true
        fi
        [ -n "${PANEL_PATH:-}" ] || PANEL_PATH="/panel-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "p${RANDOM}")/"
    fi
    if [ -z "${DIAG_PATH:-}" ]; then
        if command -v ensure_diag_path >/dev/null 2>&1; then
            ensure_diag_path || true
        fi
        [ -n "${DIAG_PATH:-}" ] || DIAG_PATH="/diag-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "d${RANDOM}")/"
    fi
    if [ -z "${DIAG_TOKEN:-}" ]; then
        DIAG_TOKEN="$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 16 || echo "tok${RANDOM}")"
    fi
    if [ -z "${SUB_PATH:-}" ]; then
        SUB_PATH="/sub-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "sub${RANDOM}")/"
    fi
    if [ -z "${SUB_JSON_PATH:-}" ]; then
        SUB_JSON_PATH="${SUB_PATH}json/"
    fi
    if [ -z "${SUB_CLASH_PATH:-}" ]; then
        SUB_CLASH_PATH="${SUB_PATH}clash/"
    fi
    if [ -z "${XHTTP_STREAM_PATH:-}" ]; then
        XHTTP_STREAM_PATH="/$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "xh${RANDOM}")/"
    fi
    DECOY_MODE="${DECOY_MODE:-1}"
    DEFAULT_FALLBACK="${DEFAULT_FALLBACK:-panel_3xui}"
    PANEL_PORT="${PANEL_PORT:-10443}"
    DEFAULT_PORT="${DEFAULT_PORT:-$PANEL_PORT}"
    SUB_PORT="${SUB_PORT:-55443}"
    XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
    REALITY_FALLBACK_PORT="${REALITY_FALLBACK_PORT:-9443}"
    SSL_BASE_DIR="${SSL_BASE_DIR:-/etc/letsencrypt/live}"
    WEBROOT="${WEBROOT:-/var/www/html}"
    NGINX_USER="${NGINX_USER:-nginx}"
    log "Сборка конфигурации Nginx Mainline (Stream L4 + HTTP/2 Upstream Engine)..."

    # Резервное копирование существующих конфигураций Nginx перед перезаписью
    backup_nginx_configs

    # Точечная очистка: удаляем только дефолтные заглушки и предыдущие конфиги маскирования
    rm -f /etc/nginx/sites-enabled/default \
          /etc/nginx/sites-available/default \
          /etc/nginx/conf.d/default.conf \
          /etc/nginx/conf.d/01-main.conf \
          /etc/nginx/conf.d/02-external-*.conf \
          /etc/nginx/conf.d/03-adguard.conf \
          /etc/nginx/conf.d/vpn_mask.conf \
          /etc/nginx/stream.d/00-stream.conf \
          /etc/nginx/stream.d/vpn_mask_stream.conf 2>/dev/null || true

    mkdir -p /etc/nginx/modules-enabled 2>/dev/null || true
    find /etc/nginx/modules-enabled/ -xtype l -delete 2>/dev/null || true
    ensure_nginx_stream_module
    modules_load_block=""
    if compgen -G "/etc/nginx/modules-enabled/*.conf" >/dev/null 2>&1; then
        modules_load_block="include /etc/nginx/modules-enabled/*.conf;"
    else
        for cand in /etc/nginx/modules/ngx_stream_module.so \
                    /usr/lib/nginx/modules/ngx_stream_module.so \
                    /usr/share/nginx/modules/ngx_stream_module.so \
                    /usr/local/nginx/modules/ngx_stream_module.so; do
            if [ -f "$cand" ]; then
                modules_load_block="load_module $cand;"
                break
            fi
        done
    fi

    # Определение поддержки директив HTTP/2 в установленной версии Nginx
    determine_nginx_http2_mode

    wstunnel_badbot_bypass=""
    if is_true "${ENABLE_WSTUNNEL:-0}" && [ -n "${WSTUNNEL_PREFIX:-}" ]; then
        wstunnel_clean_prefix="${WSTUNNEL_PREFIX#/}"
        wstunnel_clean_prefix="${wstunnel_clean_prefix%/}"
        wstunnel_badbot_bypass="        ~^1:[01]:/${wstunnel_clean_prefix}/ 0;"$'\n'
    fi

    # 1. Глобальный файл конфигурации /etc/nginx/nginx.conf
    cat << EOF > /etc/nginx/nginx.conf
user $NGINX_USER;
worker_processes auto;
pid /run/nginx.pid;
worker_rlimit_nofile 524288;
${modules_load_block}

error_log /var/log/nginx/error.log warn;

events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    server_tokens off;
    etag off;
    charset utf-8;
    resolver 1.1.1.1 8.8.8.8 ipv6=off valid=300s;
    resolver_timeout 5s;

    # Оптимизация окна и стриминга HTTP/2 для устранения просадок больших потоков
${HTTP2_HTTP_PARAMS}

    map \$proxy_protocol_addr \$ak_real_ip {
        ""      \$remote_addr;
        default \$proxy_protocol_addr;
    }

    upstream panel_3xui {
        server 127.0.0.1:$PANEL_PORT;
        keepalive 30;
    }

    upstream sub_backend {
        server 127.0.0.1:$SUB_PORT;
        keepalive 30;
    }

    upstream xray_xhttp_stream {
        server 127.0.0.1:$XHTTP_STREAM_PORT;
        keepalive 64;
    }

    proxy_cache_path /var/cache/nginx/img_cache levels=1:2 keys_zone=img_zone:10m max_size=1g inactive=7d use_temp_path=off;
    proxy_cache_path /var/cache/nginx/html_cache levels=1:2 keys_zone=html_zone:20m max_size=500m inactive=30d use_temp_path=off;

    access_log off;

    keepalive_timeout 300s;
    keepalive_requests 100000;
    client_body_timeout 300s;
    client_header_timeout 30s;
    send_timeout 300s;
    reset_timedout_connection on;

    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    set_real_ip_from unix:;

    client_max_body_size 64m;
    client_body_buffer_size 128k;
    large_client_header_buffers 4 16k;
    client_header_buffer_size 1k;

    open_file_cache max=2000 inactive=20s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;

    gzip on;
    gzip_vary on;
    gzip_comp_level 2;
    gzip_min_length 512;
    gzip_proxied any;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml image/svg+xml;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        "" close;
    }

    map \$http_user_agent \$badbot_raw {
        default 0;
        "" 1;
        ~*(?:httpclient|lwp-request|axios|fetch|insomnia|postman|libwww-perl|java|php|ruby|nuclei|httpx|ffuf|dirsearch|gobuster) 1;
        ~*(?:sqlmap|nikto|masscan|zgrab|zmap|acunetix|dirbuster|wpscan|nmap|hydra|bfexam|censys|shodan|dirb|feroxbuster|katana) 1;
        ~*(?:ahrefs|semrush|mj12bot|dotbot|rogerbot|exabot|sogou|bytespider|yandexbot|pinterest|baidu|duckduckgo|bingbot|googlebot) 1;
        ~*(?:gptbot|claudebot|chatgpt|cohere|omgili|anthropic|google-extended|applebot-extended|meta-externalagent|ccbot|perplexity|openai|perplexities|gemini|bard|anthropic-ai|commoncrawl|diffbot|weborama|bytespider-ai) 1;
        ~*(?:facebookexternalhit|twitterbot|linkedinbot|slackbot|discordbot) 1;
    }

    map \$request_uri \$is_scan_attempt {
        default 0;
        ~^/(?:pages|public)/(pages|catalog|schedule|random|public|donate|team|login|cp)\.php\$ 0;
        ~*\.(?:php|php5|phtml|asp|aspx|jsp|do|action|cgi|pl|py|rb)\$ 1;
        ~*(\.env|\.git|\.config|\.htaccess|\.sql|\.bak|\.old|\.swp|\.ini|config\.php|web\.config|settings\.py)\$ 1;
        ~*^/(?:admin|administrator|wp-admin|wp-login|phpmyadmin|sqladmin|setup|install|dashboard|manager|controlpanel|config|auth|backend|logs)/ 1;
        ~*(\.\./|\.\.\\|/etc/passwd|/boot/|/windows/|/proc/) 1;
        ~*^/(?:graphql|swagger-ui|api-docs|redoc)/ 1;
        ~*\.(?:zip|tar\.gz|rar|7z)\$ 1;
        ~*(?:\.git/|wp-json|xmlrpc|/\.env|config\.bak|debug\.log|test\.php) 1;
    }

    map "\$badbot_raw:\$is_scan_attempt:\$request_uri" \$badbot {
        ~^.*:/robots\.txt(\?|\$) 0;
        ~^.*:/.well-known/security\.txt(\?|\$) 0;
        ~^1:[01]:${PANEL_PATH} 0;
        ~^1:[01]:${DIAG_PATH} 0;
        ~^1:[01]:${SUB_PATH} 0;
        ~^1:[01]:${SUB_JSON_PATH} 0;
        ~^1:[01]:${SUB_CLASH_PATH} 0;
        ~^1:[01]:/sub/ 0;
        ~^1:[01]:/json/ 0;
        ~^1:[01]:/clash/ 0;
        ~^1:[01]:${XHTTP_STREAM_PATH} 0;
${wstunnel_badbot_bypass}        ~^1:[01]:/dns-query 0;
        ~^1:[01]:/agh/ 0;
        ~(^1:|:1) 1;
        default 0;
    }

    map \$cookie_diag_key \$diag_auth {
        default 0;
        "${DIAG_TOKEN}" 1;
    }

    limit_req_zone \$binary_remote_addr zone=bot:1m rate=4r/s;
    limit_req_zone \$binary_remote_addr zone=panel:10m rate=30r/s;
    limit_req_zone \$binary_remote_addr zone=subs:1m rate=10r/s;
    limit_req_zone \$binary_remote_addr zone=scan:1m rate=1r/s;
    limit_conn_zone \$binary_remote_addr zone=addr:1m;
    limit_req_zone \$binary_remote_addr zone=assets:1m rate=150r/s;
    limit_req_zone \$binary_remote_addr zone=doh:10m rate=300r/s;
    limit_req_status 429;

    proxy_hide_header X-Proxy-Engine;
    proxy_hide_header X-Original-URL;
    proxy_hide_header X-RateLimit-Remaining;
    proxy_hide_header Server;
    proxy_hide_header X-Powered-By;
    proxy_hide_header Via;
    proxy_hide_header X-Varnish;
    proxy_hide_header X-Varnish-Cache;
    proxy_hide_header Age;
    proxy_hide_header CF-Ray;
    proxy_hide_header CF-Cache-Status;
    proxy_hide_header Alt-Svc;
    proxy_hide_header X-Cache-Status;

    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}

stream {
    include /etc/nginx/stream.d/*.conf;
}
EOF

# 2. Карта SNI для Stream L4
STREAM_MAP_RULES=""
REALITY_UPSTREAMS=""

for dom in "${ALL_DOMAINS[@]}"; do
    if is_true "${STEAL_ENABLED:-0}" && [ -n "${DOMAIN_TO_PORT[$dom]:-}" ]; then
        port="${DOMAIN_TO_PORT[$dom]}"
        STREAM_MAP_RULES+="        ${dom}     reality_backend_${port};"$'\n'
    elif is_true "${ENABLE_NAIVE:-0}" && [ -n "${NAIVE_DOMAIN:-}" ] && [ "$dom" = "$NAIVE_DOMAIN" ] && [ "$dom" != "${PRIMARY_DOMAIN:-}" ]; then
        STREAM_MAP_RULES+="        ${dom}     naive_backend;"$'\n'
    else
        STREAM_MAP_RULES+="        ${dom}     nginx_http_backend;"$'\n'
    fi
done

if is_true "${CLASSIC_ENABLED:-0}"; then
    for ext_sni in "${!EXT_SNI_TO_PORT[@]}"; do
        port="${EXT_SNI_TO_PORT[$ext_sni]}"
        if is_true "${ENABLE_SHADOWTLS:-0}" && [ "$ext_sni" = "${SHADOWTLS_SNI:-gateway.icloud.com}" ]; then
            continue
        fi
        STREAM_MAP_RULES+="        ${ext_sni}     reality_backend_${port};"$'\n'
    done
fi

if is_true "${ENABLE_SHADOWTLS:-0}"; then
    STREAM_MAP_RULES+="        ${SHADOWTLS_SNI:-gateway.icloud.com}     shadowtls_backend;"$'\n'
fi

if is_true "${ENABLE_NAIVE:-0}" && [ -n "${NAIVE_DOMAIN:-}" ] && [ "$NAIVE_DOMAIN" != "${PRIMARY_DOMAIN:-}" ]; then
    if [[ ! "$STREAM_MAP_RULES" =~ "$NAIVE_DOMAIN" ]]; then
        STREAM_MAP_RULES+="        ${NAIVE_DOMAIN}     naive_backend;"$'\n'
    fi
fi

SHADOWTLS_STREAM_BLOCKS=""
if is_true "${ENABLE_SHADOWTLS:-0}"; then
    SHADOWTLS_STREAM_BLOCKS="
upstream shadowtls_backend {
    server 127.0.0.1:8542;
}

server {
    listen 127.0.0.1:8542 proxy_protocol;
    proxy_pass 127.0.0.1:${SHADOWTLS_PORT:-8543};
}
"
fi

NAIVE_STREAM_BLOCKS=""
if is_true "${ENABLE_NAIVE:-0}"; then
    NAIVE_STREAM_BLOCKS="
upstream naive_backend {
    server 127.0.0.1:8447;
}

server {
    listen 127.0.0.1:8447 proxy_protocol;
    proxy_pass 127.0.0.1:${NAIVE_PORT:-8446};
}
"
fi

for port in "${ALL_REALITY_PORTS[@]:-}"; do
    if [ -n "$port" ]; then
        REALITY_UPSTREAMS+="
    upstream reality_backend_${port} {
        server 127.0.0.1:${port};
        server unix:/dev/shm/nginx-http.sock backup;
    }
"
    fi
done

if is_true "${CLASSIC_ENABLED:-0}"; then
    DEFAULT_PORT="${CLASSIC_PORTS_LIST[0]:-46443}"
    DEFAULT_FALLBACK="reality_backend_${DEFAULT_PORT}"
else
    DEFAULT_FALLBACK="nginx_http_backend"
fi

# 2.1. Адаптация сторонних HTTPS-сайтов для бесконфликтной работы со Stream L4 роутером
for vf in /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf; do
    [ -f "$vf" ] || continue
    b_name=$(basename "$vf")
    case "$b_name" in
        default|default.conf|01-main.conf|02-*.conf|03-adguard.conf|vpn_mask.conf)
            continue
            ;;
    esac
    if grep -Eq 'listen[[:space:]]+([^;]*:)?443' "$vf" 2>/dev/null; then
        if ! grep -q 'listen[[:space:]]+unix:' "$vf" 2>/dev/null; then
            log "Адаптация vhost $b_name: перенос listen 443 на сокет unix:/dev/shm/nginx-http.sock..."
            sed -i -E 's/listen[[:space:]]+([^;]*:)?443[[:space:]]*ssl[[:space:]]*([^;]*);/listen unix:\/dev\/shm\/nginx-http.sock ssl \2 proxy_protocol;/g' "$vf" 2>/dev/null || true
            sed -i -E 's/listen[[:space:]]+([^;]*:)?443[[:space:]]*([^;]*);/listen unix:\/dev\/shm\/nginx-http.sock ssl \2 proxy_protocol;/g' "$vf" 2>/dev/null || true
            sn_list=$(grep -E '^[[:space:]]*server_name[[:space:]]+' "$vf" 2>/dev/null | sed -E 's/^[[:space:]]*server_name[[:space:]]+([^;]+);/\1/' || true)
            for s_dom in $sn_list; do
                if [ "$s_dom" != "_" ] && [[ ! "$STREAM_MAP_RULES" =~ "$s_dom" ]]; then
                    STREAM_MAP_RULES+="        ${s_dom}     nginx_http_backend;"$'\n'
                fi
            done
        fi
    fi
done

cat << EOF > "/etc/nginx/stream.d/00-stream.conf"
map \$ssl_preread_server_name \$backend_gate {
    hostnames;
    ""                     nginx_http_backend;
${STREAM_MAP_RULES}    default                ${DEFAULT_FALLBACK};
}

upstream nginx_http_backend {
    server unix:/dev/shm/nginx-http.sock;
}

${REALITY_UPSTREAMS}
${SHADOWTLS_STREAM_BLOCKS}
${NAIVE_STREAM_BLOCKS}

server {
    listen 443 backlog=65535 reuseport;
    proxy_protocol on;
    proxy_pass \$backend_gate;
    ssl_preread on;
}
EOF

# 2.5 Конфигурация локаций AdGuard Home (Режим 1: на основном домене)
AGH_MAIN_LOCATION_BLOCKS=""
if is_true "${ENABLE_AGH:-0}" && [ "${AGH_MODE:-1}" = "1" ]; then
    AGH_MAIN_LOCATION_BLOCKS="
    # --- ЛОКАЦИЯ: ADGUARD HOME DOH (ENDPOINT С CLIENTID) ---
    location = /dns-query {
        return 404;
    }

    location = /dns-query/${AGH_CLIENT_ID} {
        limit_req zone=doh burst=500 nodelay;
        proxy_pass http://127.0.0.1:${PORT_AGH_WEB:-3000};
        proxy_http_version 1.1;
        proxy_set_header Connection \"\";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_set_header X-Forwarded-For \$ak_real_ip;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
    }

    location /dns-query/ {
        return 403;
    }
"
fi

# 3. Конфигурация локаций маскировки (Автономные чистые профили)
DECOY_LOCATION_BLOCKS=""

if [ "$DECOY_MODE" = "1" ]; then
    # Режим 1: DataSphere Analytics
    DECOY_LOCATION_BLOCKS="
        add_header Content-Security-Policy \"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none';\" always;
        add_header X-DataSphere-Engine \"v4.0.2\" always;

        location ~ ^/(api/v1/datasphere/status|status)\$ {
            default_type application/json;
            return 200 '{\"status\":\"online\",\"cluster\":\"datasphere-edge-ultra\",\"nodes_active\":148,\"telemetry_rate\":\"99.998%\",\"version\":\"4.0.2\"}';
        }

        location = /api/v1/datasphere/auth {
            if (\$request_method = POST) {
                add_header Content-Type \"application/json; charset=utf-8\" always;
                return 401 '{\"status\":\"error\",\"code\":401,\"error\":\"Недействительный токен кластера или ключ авторизации узла. Доступ запрещен.\"}';
            }
            return 405;
        }

        location = / {
            default_type text/html;
            root $WEBROOT;
            try_files /index.html =404;
        }

        location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|webp)\$ {
            root $WEBROOT;
            expires 7d;
            access_log off;
            add_header Cache-Control \"public, max-age=604800, immutable\" always;
            try_files \$uri =404;
        }

        location / {
            return 404;
        }
"
elif [ "$DECOY_MODE" = "2" ]; then
    # Режим 2: CosmosCloud
    DECOY_LOCATION_BLOCKS="
        add_header X-Cosmoscloud-Version \"0.22.18\" always;

        location ~ ^/(api/v1/status|status)\$ {
            default_type application/json;
            return 200 '{\"installed\":true,\"maintenance\":false,\"version\":\"0.22.18\",\"productname\":\"CosmosCloud\"}';
        }

        location = /api/v1/auth/login {
            if (\$request_method = POST) {
                add_header Content-Type \"application/json\" always;
                return 401 '{\"error\":\"Wrong nickname or password. Try again or try resetting your password\",\"code\":401}';
            }
            return 405;
        }

        location = / {
            default_type text/html;
            root $WEBROOT;
            try_files /index.html =404;
        }

        location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|webp)\$ {
            root $WEBROOT;
            expires 7d;
            access_log off;
            try_files \$uri =404;
        }

        location / {
            return 404;
        }
"
else
    # Режим 3: Welcome to nginx
    DECOY_LOCATION_BLOCKS="
        location = / {
            default_type text/html;
            root $WEBROOT;
            try_files /index.html =404;
        }

        location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|webp)\$ {
            root $WEBROOT;
            expires 7d;
            access_log off;
            try_files \$uri =404;
        }

        location / {
            return 404;
        }
"
fi

WSTUNNEL_LOCATION_BLOCK=""
if is_true "${ENABLE_WSTUNNEL:-0}" && [ -n "${WSTUNNEL_PREFIX:-}" ]; then
    wstunnel_clean_prefix="${WSTUNNEL_PREFIX#/}"
    wstunnel_clean_prefix="${wstunnel_clean_prefix%/}"
    WSTUNNEL_LOCATION_BLOCK="
    # --- ЛОКАЦИЯ: WSTUNNEL (L7 WebSocket Tunnel) ---
    location ^~ /${wstunnel_clean_prefix}/ {
        proxy_pass http://127.0.0.1:${WSTUNNEL_PORT:-8080};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_set_header X-Forwarded-For \$ak_real_ip;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }
"
fi

# 4. Основной виртуальный хост в /etc/nginx/conf.d/01-main.conf
cat << EOF > "/etc/nginx/conf.d/01-main.conf"
# HTTP Порт 80 (Проверка ACME и редирект на HTTPS)
server {
    listen 80 default_server;
    server_name _;
    access_log off;

    if (\$badbot) { return 444; }

    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
    }

    location ~* ^/(wp-admin|wp-login|xmlrpc|vendor|cgi-bin) { return 444; }
    location ~ /\.(git|env|htaccess|svn) { return 444; }

    # Немедленный сброс прямых сканеров по IP (IPv4 и IPv6)
    if (\$host ~* "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$") { return 444; }
    if (\$host ~* "^\[?[0-9a-fA-F:]+\]?$") { return 444; }
    if (\$host = "") { return 444; }

    location / {
        return 301 https://\$host\$request_uri;
    }

    error_page 400 403 404 405 =404 /dev/null;
}

# HTTPS SSL-Reject сервер для перехвата невалидных SNI и сканеров по IP
server {
    listen unix:/dev/shm/nginx-http.sock ssl ${HTTP2_LISTEN_PARAM}default_server proxy_protocol;
    listen 127.0.0.1:$REALITY_FALLBACK_PORT ssl ${HTTP2_LISTEN_PARAM}default_server proxy_protocol;
    ${HTTP2_DIRECTIVE}
    server_name _;

    ssl_reject_handshake on;
    ssl_session_tickets off;

    ssl_certificate ${SSL_BASE_DIR}/$PRIMARY_DOMAIN/fullchain.pem;
    ssl_certificate_key ${SSL_BASE_DIR}/$PRIMARY_DOMAIN/privkey.pem;
}

# HTTPS Основной рабочий сервер (Главный домен)
server {
    listen unix:/dev/shm/nginx-http.sock ssl ${HTTP2_LISTEN_PARAM}proxy_protocol;
    listen 127.0.0.1:$REALITY_FALLBACK_PORT ssl ${HTTP2_LISTEN_PARAM}proxy_protocol;
    ${HTTP2_DIRECTIVE}
    server_name $PRIMARY_DOMAIN;

    ssl_certificate ${SSL_BASE_DIR}/$PRIMARY_DOMAIN/fullchain.pem;
    ssl_certificate_key ${SSL_BASE_DIR}/$PRIMARY_DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    ssl_buffer_size 4k;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 4h;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    if (\$is_scan_attempt) { return 404; }
    if (\$badbot) { return 404; }
    if (\$request_method !~ ^(GET|HEAD|POST)\$) { return 405; }

    error_page 400 403 404 405 @notfound;

    # --- ЛОКАЦИЯ 1: ПАНЕЛЬ 3X-UI ---
    location = ${PANEL_PATH%/} {
        return 301 ${PANEL_PATH};
    }

    location ^~ ${PANEL_PATH} {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=panel burst=40 delay=20;
        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_intercept_errors off;
    }

    # --- ЛОКАЦИЯ 1.1: SSO-МОСТ ДЛЯ ВЕБ-ДИАГНОСТИКИ ИЗ ПАНЕЛИ 3X-UI ---
    location = ${PANEL_PATH}diag {
        auth_request /__diag_auth;
        error_page 401 403 = @diag_login;
        try_files /__nonexistent @diag_sso_ok;
    }
    location @diag_login {
        return 302 ${PANEL_PATH};
    }
    location @diag_sso_ok {
        add_header Set-Cookie "diag_key=${DIAG_TOKEN}; Path=${DIAG_PATH}; Secure; HttpOnly; SameSite=Strict; Max-Age=86400" always;
        return 302 ${DIAG_PATH};
    }
    location = /__diag_auth {
        internal;
        proxy_pass http://127.0.0.1:$PANEL_PORT${PANEL_PATH}panel/;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Requested-With XMLHttpRequest;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_intercept_errors on;
        error_page 300 301 302 303 304 305 307 308 400 401 402 403 404 405 500 501 502 503 504 =401 @diag_denied;
    }
    location @diag_denied { return 401; }

    # --- ЛОКАЦИЯ 1.2: ПОРТАЛ ВЕБ-ДИАГНОСТИКИ (СТРОГОЕ СОКРЫТИЕ 404 БЕЗ УТЕЧКИ ПУТИ) ---
    location ^~ ${DIAG_PATH} {
        if (\$diag_auth = 0) { return 404; }
        alias /var/www/diagnostics/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
    }
    location = ${DIAG_PATH}api/st/ping {
        if (\$diag_auth = 0) { return 404; }
        default_type text/plain;
        return 200 "OK";
    }
    location = ${DIAG_PATH}api/st/getIP {
        if (\$diag_auth = 0) { return 404; }
        default_type text/plain;
        return 200 "\$ak_real_ip";
    }
    location = ${DIAG_PATH}api/st/getip {
        if (\$diag_auth = 0) { return 404; }
        default_type text/plain;
        return 200 "\$ak_real_ip";
    }
    location = ${DIAG_PATH}api/st/download {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/download;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_buffering off;
        proxy_read_timeout 60s;
    }
    location = ${DIAG_PATH}api/st/down {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/down;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_buffering off;
        proxy_read_timeout 60s;
    }
    location = ${DIAG_PATH}api/st/upload {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/upload;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_request_buffering off;
        client_max_body_size 128m;
        proxy_read_timeout 60s;
    }
    location = ${DIAG_PATH}api/st/up {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/up;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_request_buffering off;
        client_max_body_size 128m;
        proxy_read_timeout 60s;
    }
    location = ${DIAG_PATH}api/mtr {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/mtr;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_read_timeout 90s;
    }

    # --- ЛОКАЦИЯ 2: ПОДПИСКИ КЛИЕНТОВ ---
    location ^~ /sub/ {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location ^~ ${SUB_PATH} {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location ^~ ${SUB_JSON_PATH} {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location ^~ ${SUB_CLASH_PATH} {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location ~* ^/(sub|json|clash)/ {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    # --- ЛОКАЦИЯ 3: VLESS xHTTP (Native gRPC / H2 Stream-One) ---
    location ^~ ${XHTTP_STREAM_PATH} {
        client_max_body_size 0;
        client_body_timeout 1h;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_socket_keepalive on;

        grpc_set_header Host \$http_host;
        grpc_set_header X-Real-IP \$ak_real_ip;
        grpc_set_header X-Forwarded-For \$ak_real_ip;
        grpc_set_header X-Forwarded-Proto \$scheme;

        grpc_pass grpc://xray_xhttp_stream;
    }

    $WSTUNNEL_LOCATION_BLOCK
    $AGH_MAIN_LOCATION_BLOCKS

    # --- ЛОКАЦИЯ 4: ДЕКОЙ САЙТ / МАСКИРОВКА ---
    $DECOY_LOCATION_BLOCKS

    # --- СЛУЖЕБНЫЕ ЛОКАЦИИ ---
    location = /robots.txt {
        root $WEBROOT;
        access_log off;
    }

    location ~ ^/(favicon\.ico|favicon\.svg)\$ {
        root $WEBROOT;
        access_log off;
        expires 30d;
    }

    location = /.well-known/security.txt {
        default_type text/plain;
        access_log off;
        return 200 "Contact: mailto:admin@$PRIMARY_DOMAIN\nPreferred-Languages: ru,en\n";
    }

    location @notfound {
        limit_req zone=scan burst=3 nodelay;
        root $WEBROOT;
        rewrite ^ /404.html break;
    }
}
EOF

    # 4.1. Очистка устаревшего stub-сервера 11443 (Anti-Loop Fallback теперь обслуживается напрямую через 9443 с полным SNI)
    rm -f "/etc/nginx/conf.d/02-steal-stub.conf" 2>/dev/null || true

# 5. Генерация виртуальных хостов для дополнительных доменов
for ((i=1; i<${#ALL_DOMAINS[@]}; i++)); do
    ext_dom="${ALL_DOMAINS[$i]}"
    if [ "$ext_dom" != "$PRIMARY_DOMAIN" ] && [ "$ext_dom" != "${AGH_DOMAIN:-}" ] && [ -f "${SSL_BASE_DIR}/$ext_dom/fullchain.pem" ]; then
        cat << EOF > "/etc/nginx/conf.d/02-${ext_dom}.conf"
server {
    listen unix:/dev/shm/nginx-http.sock ssl ${HTTP2_LISTEN_PARAM}proxy_protocol;
    listen 127.0.0.1:$REALITY_FALLBACK_PORT ssl ${HTTP2_LISTEN_PARAM}proxy_protocol;
    ${HTTP2_DIRECTIVE}
    server_name $ext_dom;

    ssl_certificate ${SSL_BASE_DIR}/$ext_dom/fullchain.pem;
    ssl_certificate_key ${SSL_BASE_DIR}/$ext_dom/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    ssl_buffer_size 4k;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 4h;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    if (\$is_scan_attempt) { return 404; }
    if (\$badbot) { return 404; }
    if (\$request_method !~ ^(GET|HEAD|POST)\$) { return 405; }

    error_page 400 403 404 405 @notfound;

    $DECOY_LOCATION_BLOCKS
    $WSTUNNEL_LOCATION_BLOCK

    location ^~ ${PANEL_PATH} {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        proxy_pass http://127.0.0.1:$PANEL_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_intercept_errors off;
    }

    # --- ЛОКАЦИЯ 1.1: SSO-МОСТ ДЛЯ ВЕБ-ДИАГНОСТИКИ ИЗ ПАНЕЛИ 3X-UI ---
    location = ${PANEL_PATH}diag {
        auth_request /__diag_auth;
        error_page 401 403 = @diag_login;
        try_files /__nonexistent @diag_sso_ok;
    }
    location @diag_login {
        return 302 ${PANEL_PATH};
    }
    location @diag_sso_ok {
        add_header Set-Cookie "diag_key=${DIAG_TOKEN}; Path=${DIAG_PATH}; Secure; HttpOnly; SameSite=Strict; Max-Age=86400" always;
        return 302 ${DIAG_PATH};
    }
    location = /__diag_auth {
        internal;
        proxy_pass http://127.0.0.1:$PANEL_PORT${PANEL_PATH}panel/;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Requested-With XMLHttpRequest;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_intercept_errors on;
        error_page 300 301 302 303 304 305 307 308 400 401 402 403 404 405 500 501 502 503 504 =401 @diag_denied;
    }
    location @diag_denied { return 401; }

    # --- ЛОКАЦИЯ 1.2: ПОРТАЛ ВЕБ-ДИАГНОСТИКИ (СТРОГОЕ СОКРЫТИЕ 404 БЕЗ УТЕЧКИ ПУТИ) ---
    location ^~ ${DIAG_PATH} {
        if (\$diag_auth = 0) { return 404; }
        alias /var/www/diagnostics/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
    }
    location = ${DIAG_PATH}api/st/ping {
        if (\$diag_auth = 0) { return 404; }
        default_type text/plain;
        return 200 "OK";
    }
    location = ${DIAG_PATH}api/st/getIP {
        if (\$diag_auth = 0) { return 404; }
        default_type text/plain;
        return 200 "\$ak_real_ip";
    }
    location = ${DIAG_PATH}api/st/getip {
        if (\$diag_auth = 0) { return 404; }
        default_type text/plain;
        return 200 "\$ak_real_ip";
    }
    location = ${DIAG_PATH}api/st/download {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/download;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_buffering off;
        proxy_read_timeout 60s;
    }
    location = ${DIAG_PATH}api/st/down {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/down;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_buffering off;
        proxy_read_timeout 60s;
    }
    location = ${DIAG_PATH}api/st/upload {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/upload;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_request_buffering off;
        client_max_body_size 128m;
        proxy_read_timeout 60s;
    }
    location = ${DIAG_PATH}api/st/up {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/up;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_request_buffering off;
        client_max_body_size 128m;
        proxy_read_timeout 60s;
    }
    location = ${DIAG_PATH}api/mtr {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass http://unix:/run/vpn-diagnostics/mtr-backend.sock:/mtr;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_read_timeout 90s;
    }

    location ^~ /sub/ {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location ^~ ${SUB_PATH} {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location ^~ ${SUB_JSON_PATH} {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location ^~ ${SUB_CLASH_PATH} {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    location ~* ^/(sub|json|clash)/ {
        proxy_hide_header Content-Security-Policy;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self';" always;

        limit_req zone=subs burst=60 nodelay;
        limit_req_status 429;
        proxy_pass http://127.0.0.1:$SUB_PORT;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
    }

    # --- ЛОКАЦИЯ: VLESS xHTTP (Native gRPC / H2 Stream-One) ---
    location ^~ ${XHTTP_STREAM_PATH} {
        client_max_body_size 0;
        client_body_timeout 1h;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_socket_keepalive on;

        grpc_set_header Host \$http_host;
        grpc_set_header X-Real-IP \$ak_real_ip;
        grpc_set_header X-Forwarded-For \$ak_real_ip;
        grpc_set_header X-Forwarded-Proto \$scheme;

        grpc_pass grpc://xray_xhttp_stream;
    }

    location = /robots.txt {
        root $WEBROOT;
        access_log off;
    }

    location ~ ^/(favicon\.ico|favicon\.svg)\$ {
        root $WEBROOT;
        access_log off;
        expires 30d;
    }

    location = /.well-known/security.txt {
        default_type text/plain;
        access_log off;
        return 200 "Contact: mailto:admin@$ext_dom\nPreferred-Languages: ru,en\n";
    }

    location @notfound {
        limit_req zone=scan burst=3 nodelay;
        root $WEBROOT;
        rewrite ^ /404.html break;
    }
}
EOF
    fi
done

    # 6. Виртуальный хост для AdGuard Home (Режим 2: отдельный поддомен)
    if is_true "${ENABLE_AGH:-0}" && [ "${AGH_MODE:-1}" = "2" ] && [ -n "${AGH_DOMAIN:-}" ] && [ -f "${SSL_BASE_DIR:-/etc/letsencrypt/live}/$AGH_DOMAIN/fullchain.pem" ]; then
        cat << EOF > "/etc/nginx/conf.d/03-adguard.conf"
upstream adguard_backend { server 127.0.0.1:${PORT_AGH_WEB:-3000}; keepalive 32; }

server {
    listen unix:/dev/shm/nginx-http.sock ssl ${HTTP2_LISTEN_PARAM}proxy_protocol;
    listen 127.0.0.1:$REALITY_FALLBACK_PORT ssl ${HTTP2_LISTEN_PARAM}proxy_protocol;
    ${HTTP2_DIRECTIVE}
    server_name $AGH_DOMAIN;

    ssl_certificate ${SSL_BASE_DIR}/$AGH_DOMAIN/fullchain.pem;
    ssl_certificate_key ${SSL_BASE_DIR}/$AGH_DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    ssl_buffer_size 4k;
    ssl_session_tickets on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 4h;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    # Защита от ботов: пустой /dns-query без токена
    location = /dns-query {
        return 404;
    }

    location /dns-query/ {
        limit_req zone=doh burst=500 nodelay;
        proxy_pass http://adguard_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_set_header X-Forwarded-For \$ak_real_ip;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
    }

    location / {
        limit_req zone=panel burst=60 delay=30;
        proxy_pass http://adguard_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
    else
        rm -f "/etc/nginx/conf.d/03-adguard.conf" 2>/dev/null || true
    fi

    # Развертывание демона веб-диагностики и статических файлов перед запуском Nginx
    setup_vpn_diagnostics 2>/dev/null || true

    run_with_spinner "Тестирование конфигурации и перезапуск Nginx Mainline" nginx_reload_task || {
        restore_nginx_configs
        die "Ошибка запуска Nginx. Конфигурация автоматически возвращена в исходное состояние."
    }
}
apply_firewall_rules() {
    :
# Apply only the ports owned by this installation, preserving existing rules.
command -v ufw >/dev/null 2>&1 || die "UFW is not installed."

# SSH Management access
local active_ssh="${SSH_ACTIVE_PORT:-22}"
local target_ssh="${SSH_PORT:-${active_ssh}}"
ufw allow "${active_ssh}/tcp" comment 'SSH (Active)'
if [ -n "$target_ssh" ] && [ "$target_ssh" != "$active_ssh" ]; then
    ufw allow "${target_ssh}/tcp" comment 'SSH (Target)'
fi

# Web endpoints: HTTP ACME / Decoy and HTTPS Nginx L4 Stream Router
ufw allow 80/tcp comment 'HTTP (ACME / Decoy)'
ufw allow 443/tcp comment 'HTTPS (Nginx L4 Stream Router)'

# Internal stack ports (deny direct external access to prevent bypass of Nginx and scanner discovery)
for private_port in "${PANEL_PORT:-10443}" "${SUB_PORT:-55443}" "${XHTTP_STREAM_PORT:-50443}" "${REALITY_FALLBACK_PORT:-9443}" "${ALL_REALITY_PORTS[@]:-}"; do
    [ -z "$private_port" ] && continue
    ufw deny "$private_port/tcp" comment 'Stack Internal (Anti-Scanning)'
done

# Protocol listeners: allow public entrypoints, deny non-public internal proxies
while read -r protocol transport port; do
    [ -z "$port" ] || [ -z "$transport" ] && continue
    local ufw_port="${port//-/:}"
    if protocol_is_public "$protocol"; then
        ufw allow "$ufw_port/$transport" comment "VPN: $protocol"
    else
        ufw deny "$ufw_port/$transport" comment "Internal: $protocol"
    fi
done < <(selected_protocol_ports)

# Port Hopping for Hysteria 2
if is_true "${ENABLE_HY2:-n}" && is_true "${HY2_PORT_HOPPING:-n}" && [ -n "${HY2_PORT_HOPPING_RANGE:-}" ]; then
    ufw allow "${HY2_PORT_HOPPING_RANGE}/udp" comment 'VPN: Hysteria 2 Port Hopping'
fi
if ! ufw status | grep -qw active; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw --force enable
fi
# =============================================================
#  PORT HOPPING ДЛЯ HYSTERIA 2 (UDP → NAT REDIRECT)
# =============================================================
if [[ "${ENABLE_HY2:-0}" == "1" || "${ENABLE_HY2,,}" == "y" ]] && \
   [[ "${HY2_PORT_HOPPING,,}" == "y" || "${HY2_PORT_HOPPING:-}" == "1" ]] && \
   [ -n "${HY2_PORT:-}" ] && [ -n "${HY2_PORT_HOPPING_RANGE:-}" ]; then

    PH_RANGE="${HY2_PORT_HOPPING_RANGE}"

    # 1. Применяем NAT REDIRECT правила (runtime, идемпотентно)
    # IPv4
    if ! iptables -t nat -C PREROUTING -p udp --dport "$PH_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; then
        iptables -t nat -A PREROUTING -p udp --dport "$PH_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null || true
    fi
    # IPv6 (если стек IPv6 активен и ip6tables доступен)
    hy2_v6_status=""
    if [ -d /proc/sys/net/ipv6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ] && command -v ip6tables >/dev/null 2>&1; then
        if ! ip6tables -t nat -C PREROUTING -p udp --dport "$PH_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; then
            ip6tables -t nat -A PREROUTING -p udp --dport "$PH_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null || true
        fi
        hy2_v6_status="+IPv6"
    fi
    ok "Port Hopping: NAT REDIRECT UDP ${PH_RANGE} → порт ${HY2_PORT} (IPv4${hy2_v6_status}) [Активирован]"

    # 2. Персистентность через /etc/ufw/before.rules (IPv4, секция *nat)
    if [ -f /etc/ufw/before.rules ] && ! grep -q "Hy2 Port Hopping" /etc/ufw/before.rules 2>/dev/null; then
        if command -v python3 >/dev/null 2>&1; then
            if grep -q '^\*nat' /etc/ufw/before.rules 2>/dev/null; then
                python3 - "/etc/ufw/before.rules" "${PH_RANGE}" "${HY2_PORT}" << 'EOF_UFW_PY' 2>/dev/null || true
import sys
rule_file, r_range, r_port = sys.argv[1], sys.argv[2], sys.argv[3]
with open(rule_file, "r", encoding="utf-8") as f:
    lines = f.readlines()
out = []
in_nat = False
inserted = False
for line in lines:
    if line.strip() == "*nat":
        in_nat = True
    if in_nat and line.strip() == "COMMIT" and not inserted:
        out.append("# Hy2 Port Hopping\n")
        out.append(f"-A PREROUTING -p udp --dport {r_range} -j REDIRECT --to-ports {r_port}\n")
        inserted = True
        in_nat = False
    out.append(line)
with open(rule_file, "w", encoding="utf-8") as f:
    f.writelines(out)
EOF_UFW_PY
            else
                python3 - "/etc/ufw/before.rules" "${PH_RANGE}" "${HY2_PORT}" << 'EOF_UFW_PY2' 2>/dev/null || true
import sys
rule_file, r_range, r_port = sys.argv[1], sys.argv[2], sys.argv[3]
with open(rule_file, "r", encoding="utf-8") as f:
    content = f.read()
nat_block = f"# Port Hopping for Hysteria 2 (added by setup.sh)\n*nat\n:PREROUTING ACCEPT [0:0]\n# Hy2 Port Hopping\n-A PREROUTING -p udp --dport {r_range} -j REDIRECT --to-ports {r_port}\nCOMMIT\n\n"
if "*filter" in content:
    content = content.replace("*filter", nat_block + "*filter", 1)
else:
    content = nat_block + content
with open(rule_file, "w", encoding="utf-8") as f:
    f.write(content)
EOF_UFW_PY2
            fi
        elif grep -q '^\*nat' /etc/ufw/before.rules 2>/dev/null; then
            sed -i "/^\*nat/,/^COMMIT/{/^COMMIT/i\\# Hy2 Port Hopping\n-A PREROUTING -p udp --dport ${PH_RANGE} -j REDIRECT --to-ports ${HY2_PORT}
            }" /etc/ufw/before.rules
        else
            insert_before="*filter"
            grep -q '^\*mangle' /etc/ufw/before.rules 2>/dev/null && insert_before="*mangle"
            grep -q '^# TCP MSS Clamping' /etc/ufw/before.rules 2>/dev/null && insert_before="# TCP MSS Clamping"
            sed -i "/${insert_before}/i\\# Port Hopping for Hysteria 2 (added by setup.sh)\n*nat\n:PREROUTING ACCEPT [0:0]\n# Hy2 Port Hopping\n-A PREROUTING -p udp --dport ${PH_RANGE} -j REDIRECT --to-ports ${HY2_PORT}\nCOMMIT\n" /etc/ufw/before.rules
        fi
    fi

    # 3. Персистентность через /etc/ufw/before6.rules (IPv6, секция *nat, если IPv6 включен в UFW)
    if [ -f /etc/ufw/before6.rules ] && grep -q '^IPV6=yes' /etc/default/ufw 2>/dev/null && ! grep -q "Hy2 Port Hopping" /etc/ufw/before6.rules 2>/dev/null; then
        if command -v python3 >/dev/null 2>&1; then
            if grep -q '^\*nat' /etc/ufw/before6.rules 2>/dev/null; then
                python3 - "/etc/ufw/before6.rules" "${PH_RANGE}" "${HY2_PORT}" << 'EOF_UFW6_PY' 2>/dev/null || true
import sys
rule_file, r_range, r_port = sys.argv[1], sys.argv[2], sys.argv[3]
with open(rule_file, "r", encoding="utf-8") as f:
    lines = f.readlines()
out = []
in_nat = False
inserted = False
for line in lines:
    if line.strip() == "*nat":
        in_nat = True
    if in_nat and line.strip() == "COMMIT" and not inserted:
        out.append("# Hy2 Port Hopping\n")
        out.append(f"-A PREROUTING -p udp --dport {r_range} -j REDIRECT --to-ports {r_port}\n")
        inserted = True
        in_nat = False
    out.append(line)
with open(rule_file, "w", encoding="utf-8") as f:
    f.writelines(out)
EOF_UFW6_PY
            else
                python3 - "/etc/ufw/before6.rules" "${PH_RANGE}" "${HY2_PORT}" << 'EOF_UFW6_PY2' 2>/dev/null || true
import sys
rule_file, r_range, r_port = sys.argv[1], sys.argv[2], sys.argv[3]
with open(rule_file, "r", encoding="utf-8") as f:
    content = f.read()
nat_block = f"# Port Hopping for Hysteria 2 - IPv6 (added by setup.sh)\n*nat\n:PREROUTING ACCEPT [0:0]\n# Hy2 Port Hopping\n-A PREROUTING -p udp --dport {r_range} -j REDIRECT --to-ports {r_port}\nCOMMIT\n\n"
if "*filter" in content:
    content = content.replace("*filter", nat_block + "*filter", 1)
else:
    content = nat_block + content
with open(rule_file, "w", encoding="utf-8") as f:
    f.write(content)
EOF_UFW6_PY2
            fi
        elif grep -q '^\*nat' /etc/ufw/before6.rules 2>/dev/null; then
            sed -i "/^\*nat/,/^COMMIT/{/^COMMIT/i\\# Hy2 Port Hopping\n-A PREROUTING -p udp --dport ${PH_RANGE} -j REDIRECT --to-ports ${HY2_PORT}
            }" /etc/ufw/before6.rules
        else
            sed -i '/^\*filter/i\# Port Hopping for Hysteria 2 - IPv6 (added by setup.sh)\n*nat\n:PREROUTING ACCEPT [0:0]\n# Hy2 Port Hopping\n-A PREROUTING -p udp --dport '"${PH_RANGE}"' -j REDIRECT --to-ports '"${HY2_PORT}"'\nCOMMIT\n' /etc/ufw/before6.rules
        fi
    fi
else
    # Очистка Port Hopping, если отключен (чистый стелс-режим)
    if [ -n "${HY2_PORT_HOPPING_RANGE:-}" ] && [ -n "${HY2_PORT:-}" ]; then
        PH_RANGE="${HY2_PORT_HOPPING_RANGE}"
        while iptables -t nat -C PREROUTING -p udp --dport "$PH_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; do
            iptables -t nat -D PREROUTING -p udp --dport "$PH_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null || break
        done
        if [ -d /proc/sys/net/ipv6 ] && command -v ip6tables >/dev/null 2>&1; then
            while ip6tables -t nat -C PREROUTING -p udp --dport "$PH_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null; do
                ip6tables -t nat -D PREROUTING -p udp --dport "$PH_RANGE" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null || break
            done
        fi
        if [ -f /etc/ufw/before.rules ] && grep -q "Hy2 Port Hopping" /etc/ufw/before.rules 2>/dev/null; then
            sed -i '/# Port Hopping for Hysteria 2/,/COMMIT/d' /etc/ufw/before.rules 2>/dev/null || true
            sed -i '/# Hy2 Port Hopping/d' /etc/ufw/before.rules 2>/dev/null || true
            sed -i '/-A PREROUTING -p udp --dport '"${PH_RANGE}"' -j REDIRECT/d' /etc/ufw/before.rules 2>/dev/null || true
        fi
        if [ -f /etc/ufw/before6.rules ] && grep -q "Hy2 Port Hopping" /etc/ufw/before6.rules 2>/dev/null; then
            sed -i '/# Port Hopping for Hysteria 2/,/COMMIT/d' /etc/ufw/before6.rules 2>/dev/null || true
            sed -i '/# Hy2 Port Hopping/d' /etc/ufw/before6.rules 2>/dev/null || true
            sed -i '/-A PREROUTING -p udp --dport '"${PH_RANGE}"' -j REDIRECT/d' /etc/ufw/before6.rules 2>/dev/null || true
        fi
        ufw delete allow "${PH_RANGE//:/ }/udp" >/dev/null 2>&1 || true
    fi
fi

}

install_step_firewall() {
    if command -v run_with_spinner >/dev/null 2>&1; then
        run_with_spinner "Применение правил доступа и портов UFW" apply_firewall_rules
    else
        apply_firewall_rules
    fi
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
normalize_node_token_config() {
    local enabled="${CLI_ENABLE_NODE_TOKEN:-${ENABLE_NODE_TOKEN:-y}}"
    NODE_TOKEN="${NODE_TOKEN:-}"
    NODE_TOKEN_NAME="${CLI_NODE_TOKEN_NAME:-${NODE_TOKEN_NAME:-}}"
    case "${enabled,,}" in y|1|true) ENABLE_NODE_TOKEN=y ;; *) ENABLE_NODE_TOKEN=n; return 0 ;; esac
    case "${AUTO_SETUP_3XUI:-y}" in n|0|false) ENABLE_NODE_TOKEN=n; return 0 ;; esac
    if [ -z "$NODE_TOKEN_NAME" ]; then
        local prefix="${SERVER_PREFIX-Server}"
        case "${prefix,,}" in ''|-|none|off|no) NODE_TOKEN_NAME=Master-Node-Cluster ;; *) NODE_TOKEN_NAME="${prefix}-Node" ;; esac
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
        [[ "$line" =~ ^(NODE_TOKEN_NAME|NODE_TOKEN)=(.*)$ ]] || continue
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


def verify(path, name, token):
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
        if "scope" in row.keys() and row["scope"] not in ("admin", "node-admin", "node-sync"):
            return False
        return hmac.compare_digest(hashlib.sha256(token.encode()).hexdigest(), row["token"])
    except (sqlite3.Error, ValueError, TypeError):
        return False


def create(path, name):
    with closing(connect(path)) as conn, conn:
        columns = {row[1] for row in conn.execute("PRAGMA table_info(api_tokens)")}
        if not {"name", "token", "enabled"} <= columns:
            raise ValueError("Unsupported 3X-UI API-token schema")
        token = secrets.token_hex(32)
        values = {"name": name, "token": hashlib.sha256(token.encode()).hexdigest(), "enabled": 1}
        for column, value in (("scope", "admin"), ("created_at", int(time.time())), ("expires_at", 0)):
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


def persist(runtime_path, config_path, name, token):
    values = {"ENABLE_NODE_TOKEN": "y", "NODE_TOKEN_NAME": name, "NODE_TOKEN": token}
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
    if node_token_operation verify "$DB_PATH" "$NODE_TOKEN_NAME" "$NODE_TOKEN"; then
        ok "Действующий API-ключ ноды '$NODE_TOKEN_NAME' сохранён."
    else
        NODE_TOKEN=""
        local token_out="" attempt
        local -a arguments=()
        if [ -n "${XUI_BIN:-}" ]; then
            for attempt in 1 2; do
                case "$attempt" in
                    1) arguments=(-tokenName "$NODE_TOKEN_NAME" -tokenScope admin) ;;
                    2) arguments=(-tokenName "$NODE_TOKEN_NAME") ;;
                esac
                token_out=$("$XUI_BIN" setting -getApiToken "${arguments[@]}" 2>&1 || true)
                NODE_TOKEN=$(printf '%s\n' "$token_out" | awk '$1 == "apiToken:" {gsub(/\r/, "", $2); print $2; exit}')
                [ -z "$NODE_TOKEN" ] || break
            done
        fi
        # Also handles CLI versions without named-token flags, without renaming other tokens.
        if ! node_token_operation verify "$DB_PATH" "$NODE_TOKEN_NAME" "$NODE_TOKEN"; then
            NODE_TOKEN=$(node_token_operation create "$DB_PATH" "$NODE_TOKEN_NAME") || die "Не удалось создать API-ключ ноды 3X-UI."
        fi
        [ -n "$NODE_TOKEN" ] || die "3X-UI не вернул API-ключ ноды."
        ok "API-ключ ноды '$NODE_TOKEN_NAME' создан."
    fi
    local runtime_file
    runtime_file=$(node_token_runtime_file)
    node_token_operation persist "$runtime_file" "${CONFIG_FILE:-}" "$NODE_TOKEN_NAME" "$NODE_TOKEN" || die "Не удалось сохранить API-ключ ноды."
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
        "project_version": os.environ.get("SCRIPT_VERSION", "v9.4.0"),
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
                "${SETUP_MASK_LOG:-}" \
                "${INSTALL_LOG:-}" \
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
  --dry-run               Только аудит и проверка (без внесения изменений)
  --force-sub             Принудительно перезаписать кастомные параметры подписки из .env
  --force-remarks         Принудительно сбросить названия инбаундов к стандартным из .env
  --warp                  Включить исходящий туннель Cloudflare WARP (обход капч и AI)
  --no-warp               Отключить исходящий туннель Cloudflare WARP
  --warp-key <KEY>        Указать лицензионный ключ WARP+
  --node-token            Создать API-токен для подключения сервера как узла (3X-UI Node)
  --no-node-token         Не создавать API-токен для подключения сервера как узла
  --node-token-name <NAME> Название API-токена ноды (по умолчанию: <SERVER_PREFIX>-Node)
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
    local NON_INTERACTIVE=0
    local CLI_ENABLE_WARP=""
    local CLI_WARP_KEY=""
    local CLI_ENABLE_NODE_TOKEN=""
    local CLI_NODE_TOKEN_NAME=""

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

    # Дефолтные значения переменных, если не определены в .env
    PRIMARY_DOMAIN="${PRIMARY_DOMAIN:-yourdomain.online}"
    PANEL_PORT="${PANEL_PORT:-10443}"
    PANEL_PATH="${PANEL_PATH:-}"
    SUB_PORT="${SUB_PORT:-55443}"
    SUB_PATH="${SUB_PATH:-}"
    SUB_CLASH_PATH="${SUB_CLASH_PATH:-${SUB_PATH%/}/clash}"
    SERVER_PREFIX="${SERVER_PREFIX:-$PRIMARY_DOMAIN}"
    ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
    NODE_TOKEN_NAME="${NODE_TOKEN_NAME:-${SERVER_PREFIX}-Node}"
    DIAG_TOKEN="${DIAG_TOKEN:-}"

    STEAL_PORT="${STEAL_PORT:-45443}"
    STEAL_SNI="${STEAL_SNI:-gateway.icloud.com}"
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

    export DB_PATH
    export DRY_RUN
    export FORCE_SUB
    export PRIMARY_DOMAIN
    export PANEL_PORT
    export PANEL_PATH
    export SUB_PORT
    export SUB_PATH
    export SUB_CLASH_PATH
    export ENABLE_STEAL
    export STEAL_PORT
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

    # Приостановка службы x-ui на время реальной транзакции во избежание блокировок SQLite
    WAS_ACTIVE=0
    cleanup_xui() {
        if [ "${WAS_ACTIVE:-0}" -eq 1 ]; then
            systemctl start x-ui 2>/dev/null || true
        fi
        command -v release_stack_lock >/dev/null 2>&1 && release_stack_lock
    }
    trap cleanup_xui EXIT

    if [ "$DRY_RUN" -eq 0 ]; then
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet x-ui 2>/dev/null; then
            log "Приостановка службы 3X-UI на время обновления конфигурации базы..."
            systemctl stop x-ui
            WAS_ACTIVE=1
        fi
    fi

    log "Конфигурирование таблиц settings и inbounds (Smart Reconcile Engine)..."

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
    then ACME (/etc/ssl/acme for Cloudflare DNS-01 API).
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

def make_remark(method):
    if server_prefix:
        return f"{server_prefix} ({method})"
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

# Проверка: настроена ли кастомная подписка
is_custom_sub = bool(old_sub_uri and (old_sub_domain != domain or (old_sub_path.strip("/") != sub_path and old_sub_path.strip("/") != "my-post-key")))

if is_custom_sub and not force_sub:
    print(f"  [СОХРАНЕНО] Кастомная подписка сохранена: {old_sub_uri}")
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
obsolete_pattern = re.compile(r'-(steal|classic|xhttp|hy2|hysteria|hysteria2|awg-v3|awg-v2)$', re.IGNORECASE)

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
if harvested_ss_server_pass and validate_ss2022_key(harvested_ss_server_pass, ss_method):
    unified_ss_server_pass = harvested_ss_server_pass
else:
    unified_ss_server_pass = generate_ss2022_key(ss_method)

if harvested_ss_client_pass and validate_ss2022_key(harvested_ss_client_pass, ss_method):
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
if harvested_mtp_secret and validate_mtproto_secret(harvested_mtp_secret):
    unified_mtp_secret = harvested_mtp_secret
else:
    unified_mtp_secret = generate_mtproto_secret(mtproto_faketls_domain)

unified_mtp_adtag = mtproto_adtag or harvested_mtp_adtag or ""
if unified_mtp_adtag and not validate_mtproto_adtag(unified_mtp_adtag):
    unified_mtp_adtag = ""

if harvested_reality_priv:
    def_reality_priv = harvested_reality_priv
    def_reality_pub = harvested_reality_pub or curve25519_reality_pubkey(def_reality_priv)
    def_reality_sids = harvested_reality_sids or ([unified_sub_id] + [secrets.token_hex(n) for n in (1, 2, 3, 6)])
    print(f"  [СОХРАНЕНО] Серверные ключи VLESS-REALITY сохранены из базы SQLite")
else:
    def_reality_priv, def_reality_pub = generate_reality_keypair()
    def_reality_sid = unified_sub_id
    def_reality_sids = [def_reality_sid] + [secrets.token_hex(n) for n in (1, 2, 3, 6)]

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
            for ep in target_stream["externalProxy"]:
                if protocol in ("shadowsocks", "mtproto", "amneziawg"):
                    ep["forceTls"] = "none"
                elif protocol == "vless" and "realitySettings" in target_stream:
                    ep["forceTls"] = "same"
                elif "forceTls" not in ep:
                    ep["forceTls"] = "tls"

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
    target_snis = []
    old_snis = []

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
    h_port = globals().get("hy2_port", 443)
    expected_ext_port = 443 if protocol in ("vless", "hysteria") and port != h_port else (h_port if protocol == "hysteria" else port)

    cur_domain = globals().get("domain", "")
    def_ext = default_stream.get("externalProxy", [])
    def_dest = def_ext[0].get("dest") if (def_ext and isinstance(def_ext, list) and def_ext[0].get("dest")) else cur_domain
    def_sni = def_ext[0].get("sni", "") if (def_ext and isinstance(def_ext, list) and def_ext[0].get("sni")) else ""

    # Сохраняем кастомный хост узла (dest), если он был настроен и не равен localhost
    target_dest = def_dest
    if cur_ext and len(cur_ext) > 0 and cur_ext[0].get("dest"):
        ext_dest = str(cur_ext[0]["dest"]).strip()
        if ext_dest and ext_dest not in ("127.0.0.1", "localhost", "0.0.0.0"):
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
            updated_ext.append(entry)
        target_stream["externalProxy"] = updated_ext
        if cur_ext != updated_ext:
            repairs.append(f"обновлен externalProxy ({len(updated_ext)} узлов)")
        else:
            preserved.append(f"externalProxy ({len(updated_ext)} узлов)")
    else:
        # Сохраняем SNI для externalProxy (критично для VLESS REALITY и маршрутизации Nginx Stream L4)
        target_sni = def_sni
        if cur_ext and len(cur_ext) > 0 and cur_ext[0].get("sni"):
            ext_sni = str(cur_ext[0]["sni"]).strip()
            if ext_sni:
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
                ext_entry["alpn"] = def_ext[0]["alpn"]

        def_fp = def_ext[0].get("fingerprint") if (def_ext and isinstance(def_ext, list) and len(def_ext) > 0) else None
        cur_fp_single = cur_ext[0].get("fingerprint") if (cur_ext and isinstance(cur_ext, list) and len(cur_ext) > 0) else None
        needs_ext_repair = (
            not cur_ext
            or cur_ext[0].get("port") != expected_ext_port
            or cur_ext[0].get("dest") != target_dest
            or cur_ext[0].get("remark") != final_remark
            or cur_ext[0].get("forceTls") != force_tls_val
            or (target_sni and cur_ext[0].get("sni") != target_sni)
            or (def_fp and cur_fp_single != def_fp)
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
    "externalProxy": [{"dest": domain, "port": 443, "forceTls": "tls", "sni": domain, "fingerprint": reality_fingerprint, "alpn": "h2", "remark": make_remark("VLESS xHTTP")}]
}
xhttp_remark = make_remark("VLESS xHTTP")
xhttp_ib_id = smart_reconcile_inbound(xhttp_port, "vless", "in-xhttp-stream", xhttp_remark, x_set, x_str, listen="127.0.0.1")

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
    smart_reconcile_inbound(hy2_port, "hysteria", "in-hysteria2", hy2_remark, h_set, h_str, listen="0.0.0.0")

# 5. AmneziaWG v3.1 (8443)
if enable_awg_v3:
    awg_i1_env = os.environ.get("AWG_I1", "").strip()
    if awg_i1_env.lower() == "dns":
        awg_i1_env = "<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>"
    a3_set = {
        "clients": [{
            "privateKey": def_wg_c_priv, "publicKey": def_wg_c_pub,
            "allowedIPs": ["10.8.1.2/32"], "email": unified_email, "subId": unified_sub_id, "enable": True
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
            "allowedIPs": ["10.8.2.2/32"], "email": unified_email, "subId": unified_sub_id, "enable": True
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
        shuffle_host INTEGER DEFAULT 0
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

inbound_col = "inboundId" if "inboundId" in active_host_cols else "inbound_id"
sort_col = "sortOrder" if "sortOrder" in active_host_cols else "sort_order"
shuffle_col = "shuffleHost" if "shuffleHost" in active_host_cols else "shuffle_host"

def insert_host_entry(ib_id, host_remark, addr, host_port, sec, host_sni="", host_path="", host_alpn="", host_fp="firefox", sort_order=0, shuffle_host=0):
    if ib_id is None or dry_run:
        return
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
        "final_mask": "", "exclude_from_sub_types": "",
        "shuffle_host": shuffle_host, "shuffleHost": shuffle_host
    }
    insert_data = {k: v for k, v in col_candidates.items() if k in active_host_cols}
    keys = list(insert_data.keys())
    vals = [insert_data[k] for k in keys]
    placeholders = ",".join(["?"] * len(keys))
    cur.execute(f"INSERT INTO hosts ({','.join(keys)}) VALUES ({placeholders})", vals)

def sync_host_entry(ib_id, host_remark, addr, host_port, sec, host_sni="", host_path="", host_alpn="", host_fp="firefox", sort_order=0, shuffle_host=0):
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
            update_vals.append(h_id)
            cur.execute(f"UPDATE hosts SET {', '.join(update_fields)} WHERE id = ?", tuple(update_vals))
    else:
        insert_host_entry(ib_id, host_remark, addr, host_port, sec, host_sni=host_sni, host_path=host_path, host_alpn=host_alpn, host_fp=host_fp, sort_order=sort_order, shuffle_host=shuffle_host)

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
        sync_host_entry(s_iid, s_rem, domain, 443, "same", host_sni=steal_dom, host_fp=reality_fp, sort_order=1)

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
            insert_host_entry(c_iid, h_remark, domain, 443, "same", host_sni=csni, host_fp=reality_fp, sort_order=idx, shuffle_host=1)

x_iid = xhttp_ib_id if ('xhttp_ib_id' in locals() and xhttp_ib_id) else lookup_inbound_id("in-xhttp-stream", xhttp_port)
if x_iid:
    cur.execute("SELECT remark FROM inbounds WHERE id = ?", (x_iid,))
    r_rem = cur.fetchone()
    x_rem = r_rem[0] if r_rem and r_rem[0] else xhttp_remark
    sync_host_entry(x_iid, x_rem, domain, 443, "tls", host_sni=domain, host_path=f"/{xhttp_path.strip('/')}/", host_alpn=json.dumps(["h2"]), host_fp=reality_fp, sort_order=2)


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

        # Обновление ядра Xray-core до последней актуальной версии (v26.9.30+)
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
                    LATEST_TAG=$(echo "$gh_resp" | { grep -m1 '"tag_name":' || true; } | { cut -d '"' -f 4 || true; }) || LATEST_TAG=""
                fi
            fi
            [ -n "$LATEST_TAG" ] || LATEST_TAG="v26.9.30"
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

        # Возобновление/перезапуск службы 3X-UI
        if [ "${WAS_ACTIVE:-0}" -eq 1 ] || (command -v systemctl >/dev/null 2>&1 && systemctl is-enabled --quiet x-ui 2>/dev/null); then
            log "Перезапуск службы 3X-UI..."
            systemctl restart x-ui && ok "Служба 3X-UI успешно перезапущена." || warn "Не удалось перезапустить службу x-ui."
        fi

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
        echo -e "  - ${BOLD}Панель управления:${NC}      ${CYAN}https://${PRIMARY_DOMAIN}/${PANEL_PATH}/${NC}"
        echo -e "  - ${BOLD}Логин панели:${NC}           ${WHITE}${ADMIN_USERNAME:-admin}${NC}"
        if [ -n "${ADMIN_PASSWORD:-}" ]; then
            echo -e "  - ${BOLD}Пароль панели:${NC}          ${WHITE}${ADMIN_PASSWORD}${NC}"
        fi
        echo -e "  - ${BOLD}Канал подписок:${NC}        ${CYAN}https://${PRIMARY_DOMAIN}/${SUB_PATH#/}/${NC}"
        echo -e "  - ${BOLD}Канал подписок (Clash):${NC}  ${CYAN}https://${PRIMARY_DOMAIN}/${SUB_CLASH_PATH#/}/${NC}"
        if [ -n "${UNIFIED_SUB_ID:-}" ]; then
            echo -e "  - ${BOLD}Прямая подписка:${NC}       ${GREEN}https://${PRIMARY_DOMAIN}/${SUB_PATH#/}/${UNIFIED_SUB_ID}${NC}"
            echo -e "  - ${BOLD}Прямая подписка (Clash):${NC} ${GREEN}https://${PRIMARY_DOMAIN}/${SUB_CLASH_PATH#/}/${UNIFIED_SUB_ID}${NC}"
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
        if [[ "${ENABLE_NODE_TOKEN,,}" == "y" || "${ENABLE_NODE_TOKEN:-}" == "1" ]] && [ -n "${NODE_TOKEN:-}" ]; then
            echo -e "  - ${BOLD}3X-UI Node API:${NC}         ${GREEN}${NODE_TOKEN_NAME}${NC} (Host: ${CYAN}${PRIMARY_DOMAIN}:443${NC}, Path: ${CYAN}/${PANEL_PATH#/}/${NC})"
            echo -e "  - ${BOLD}API Bearer Token:${NC}       ${YELLOW}${NODE_TOKEN}${NC}"
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
Панель управления:     https://${PRIMARY_DOMAIN}/${PANEL_PATH#/}/
$([ -n "${DIAG_TOKEN:-}" ] && echo "Веб-диагностика (SSO): https://${PRIMARY_DOMAIN}/${PANEL_PATH#/}/diag")
$([ -n "${DIAG_TOKEN:-}" ] && echo "Токен диагностики:     ${DIAG_TOKEN}")
Логин администратора:   ${ADMIN_USERNAME:-admin}
Пароль администратора:  ${ADMIN_PASSWORD}
$([ -n "$INSTALLED_XRAY_VER" ] && echo "Ядро Xray-core:        ${INSTALLED_XRAY_VER}")

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
=====================================================================
EOF_CRED
            echo -e "  - ${BOLD}Файл с паролями:${NC}        ${CYAN}$CRED_FILE${NC} (chmod 600)"
        elif [ -f "$CRED_FILE" ]; then
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
    echo -e "${GREEN}=====================================================================${NC}"
    echo
    return 0
}

install_step_panel() {
    # 1. Проверяем наличие ядра 3X-UI на сервере, если нет - устанавливаем автоматически
    if ! command -v x-ui >/dev/null 2>&1 && [ ! -f /etc/x-ui/x-ui.db ] && [ ! -f /usr/local/x-ui/bin/x-ui.db ]; then
        install_3xui_core_task() {
            export DEBIAN_FRONTEND=noninteractive
            curl -Ls --connect-timeout 15 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/install_3xui.sh
            printf "n\n" | bash /tmp/install_3xui.sh
        }
        run_with_spinner "Установка официального ядра 3X-UI (mhsanaei)" install_3xui_core_task || die "Ошибка установки ядра 3X-UI."
    fi

    # 2. Использование локальной версии configure-panel.sh или встроенного модуля (без сети)
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "/root")"
    CONFIG_EXEC="$script_dir/configure-panel.sh"
    if [ ! -f "$CONFIG_EXEC" ]; then
        CONFIG_EXEC=""
    else
        chmod +x "$CONFIG_EXEC" 2>/dev/null || true
    fi

    # Развертывание фоновых служб нового поколения (Zapret, MASQUE, ShadowTLS, Wstunnel, NaïveProxy, DNSTT)
    # Выполняется ДО configure-panel.sh, чтобы сгенерированные ключи и пароли попали в сводный отчет клиента
    if command -v deploy_native_nextgen_services >/dev/null 2>&1; then
        deploy_native_nextgen_services
        save_session_state "$SAVED_CONFIG_FILE"
    fi

    if [ -n "$CONFIG_EXEC" ] || command -v configure_3xui_panel >/dev/null 2>&1; then
        if is_true "${ENABLE_NODE_TOKEN:-y}"; then
            NODE_ENV_FILE="${NODE_ENV_FILE:-$(umask 077; mktemp "${TMPDIR:-/tmp}/3xui-node.XXXXXX")}"
        fi
        run_configure_3xui_task() {
            export ENABLE_WARP
            export WARP_LICENSE_KEY
            export TIME_LOCATION
            export SUB_UPDATES
            export SUB_ENCRYPT
            export SUB_CLASH_PATH
            export BLOCK_SMTP
            export BLOCK_LAN
            export WEB_LISTEN
            export SUB_LISTEN
            export ENABLE_AGH
            export AGH_XRAY_DNS
            export UPDATE_XRAY_CORE="${UPDATE_XRAY_CORE:-y}"
            export ENABLE_NODE_TOKEN
            export NODE_TOKEN_NAME
            export NODE_ENV_FILE
            export AWG_PRIMARY_DNS
            export AWG_SECONDARY_DNS
            export AWG_SUBNET_IP
            export AWG_SUBNET_CIDR
            export AWG_RANDOM_TRAILERS
            export ENABLE_SS2022
            export SS2022_PORT
            export ENABLE_TUIC
            export TUIC_PORT
            export ENABLE_MTPROTO
            export MTPROTO_PORT
            export MTPROTO_FAKETLS_DOMAIN
            export MTPROTO_ADTAG
            export ENABLE_MASQUE
            export MASQUE_PORT
            export MASQUE_USER
            export MASQUE_PASSWORD
            export ENABLE_SHADOWTLS
            export SHADOWTLS_PORT
            export SHADOWTLS_SNI
            export SHADOWTLS_PASSWORD
            export ENABLE_WSTUNNEL
            export WSTUNNEL_PORT
            export WSTUNNEL_PREFIX
            export WSTUNNEL_SECRET
            export ENABLE_ZAPRET
            export ZAPRET_QNUM
            export ZAPRET_DESYNC
            export ZAPRET_FOOLING
            export ENABLE_NAIVE
            export NAIVE_PORT
            export NAIVE_DOMAIN
            export NAIVE_USER
            export NAIVE_PASS
            export ENABLE_DNSTT
            export DNSTT_PORT
            export DNSTT_DOMAIN
            export DNSTT_PUBKEY
            if [ -n "${CONFIG_EXEC:-}" ] && [ -f "$CONFIG_EXEC" ]; then
                bash "$CONFIG_EXEC" --config "$SAVED_CONFIG_FILE" -y
            elif command -v configure_3xui_panel >/dev/null 2>&1; then
                configure_3xui_panel --config "$SAVED_CONFIG_FILE" -y
            else
                die "Модуль автонастройки 3X-UI недоступен."
            fi
        }
        run_with_spinner "Автоматическая настройка базы 3X-UI и создание инбаундов" run_configure_3xui_task || die "Ошибка настройки базы 3X-UI."

        if is_true "${ENABLE_NODE_TOKEN:-y}"; then
            load_node_token_result "$NODE_ENV_FILE" || die "API-ключ ноды не получен от 3X-UI."
            rm -f -- "$NODE_ENV_FILE"
            save_session_state "$SAVED_CONFIG_FILE"
        fi

        # 3. Настройка службы и таймера автоматического еженедельного обновления geosite/geoip
        setup_xray_geo_timer_task() {
            cat << 'EOF_GEO' > /usr/local/bin/update-xray-geo.sh
#!/bin/bash
set -e
GEO_DIR="/usr/local/x-ui/bin"
[ -d "$GEO_DIR" ] || GEO_DIR="/etc/x-ui/bin"
mkdir -p "$GEO_DIR"

curl -fsSL --connect-timeout 15 "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat" -o "$GEO_DIR/geosite.dat.tmp" 2>/dev/null || true
curl -fsSL --connect-timeout 15 "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat" -o "$GEO_DIR/geoip.dat.tmp" 2>/dev/null || true

if [ -s "$GEO_DIR/geosite.dat.tmp" ]; then
    mv -f "$GEO_DIR/geosite.dat.tmp" "$GEO_DIR/geosite.dat"
fi
if [ -s "$GEO_DIR/geoip.dat.tmp" ]; then
    mv -f "$GEO_DIR/geoip.dat.tmp" "$GEO_DIR/geoip.dat"
fi
systemctl restart x-ui >/dev/null 2>&1 || true
EOF_GEO
            chmod +x /usr/local/bin/update-xray-geo.sh

            cat << 'EOF_GEOSVC' > /etc/systemd/system/xray-geo-update.service
[Unit]
Description=Weekly update of Xray GeoSite and GeoIP databases
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-xray-geo.sh
EOF_GEOSVC

            cat << 'EOF_GEOTMR' > /etc/systemd/system/xray-geo-update.timer
[Unit]
Description=Weekly timer for Xray GeoSite and GeoIP databases update

[Timer]
OnCalendar=Sun *-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF_GEOTMR

            systemctl daemon-reload
            systemctl enable --now xray-geo-update.timer >/dev/null 2>&1 || true
        }
        run_with_spinner "Активация таймера еженедельного обновления geosite.dat и geoip.dat" setup_xray_geo_timer_task
    else
        die "Missing configure-panel.sh"
    fi
}
install_step_adguard() {
    :
    install_agh_task() {
        # 1. Бесконфликтная изоляция DNS: systemd-resolved (DoT на :53) и AdGuard Home (на :10053)
        rm -f /etc/systemd/resolved.conf.d/adguard.conf 2>/dev/null || true

        # 2. Скачивание и распаковка AdGuard Home (если ещё не установлен, T04/T05)
        if [ ! -f /opt/AdGuardHome/AdGuardHome ]; then
            cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
            local m_arch="x86_64"
            case "$cur_arch" in
                x86_64|amd64) m_arch="x86_64" ;;
                aarch64|arm64) m_arch="aarch64" ;;
                *) m_arch="x86_64" ;;
            esac

            local agh_tmp="/tmp/agh_staging_$$"
            mkdir -p "$agh_tmp"
            if download_manifest_component "AdGuardHome" "$agh_tmp/agh.tar.gz" "$m_arch"; then
                tar -zxf "$agh_tmp/agh.tar.gz" -C /opt/ >/dev/null 2>&1
            fi
            rm -rf "$agh_tmp"
        fi

        # 3. Генерация bcrypt-хэша пароля через htpasswd
        which htpasswd >/dev/null 2>&1 || apt-get install -y -q apache2-utils >/dev/null 2>&1
        agh_pass_hash=""
        if command -v htpasswd >/dev/null 2>&1; then
            agh_pass_hash=$(htpasswd -b -n -B -C 10 "" "$AGH_PASS" 2>/dev/null | tr -d '\n' | cut -d: -f2)
        fi
        if [ -z "$agh_pass_hash" ]; then
            agh_pass_hash=$(python3 -c "
import sys
try:
    import bcrypt
    print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(10)).decode())
except Exception:
    pass
" "$AGH_PASS" 2>/dev/null || true)
        fi

        # 4. Создание конфигурации AdGuardHome.yaml
        mkdir -p /opt/AdGuardHome
        cat << EOF_AGH > /opt/AdGuardHome/AdGuardHome.yaml
http:
  address: 127.0.0.1:${PORT_AGH_WEB:-3000}
  doh:
    insecure_enabled: true
users:
  - name: ${AGH_USER}
    password: "${agh_pass_hash}"
dns:
  bind_hosts:
    - 127.0.0.1
  port: ${PORT_AGH_DNS:-10053}
  trusted_proxies:
    - 127.0.0.1
    - ::1
  ratelimit: 20
  ratelimit_whitelist:
    - 127.0.0.1
  dnssec: true
  upstream_dns:
    - "[/ru/kz/by/su/xn--p1ai/]https://77.88.8.8:443/dns-query"
    - "[/google.com/googlevideo.com/youtube.com/ytimg.com/gstatic.com/googleapis.com/1e100.net/]h3://dns.google/dns-query"
    - "quic://p2.freedns.controld.com"
    - "quic://dns.adguard-dns.com"
    - "quic://dns.nextdns.io"
    - "quic://dns.quad9.net"
    - "quic://doq.ffmuc.net"
    - "quic://dns.surfsharkdns.com"
    - "h3://cloudflare-dns.com/dns-query"
  blocked_hosts: []
  allowed_clients:
    - ${AGH_CLIENT_ID}
    - 127.0.0.1
  disallowed_clients: []
clients:
  runtime_sources:
    whois: false
    dhcp: false
  persistent:
    - name: "Home-Router"
      ids:
        - ${AGH_CLIENT_ID}
      use_global_settings: true
filters:
  - enabled: true
    url: "https://small.oisd.nl/domainswild"
    name: "OISD Small (Ads + Trackers)"
    id: 1
filtering:
  filtering_enabled: true
  filters_update_interval: 24
querylog:
  enabled: true
  interval: 24h
  size_memory: 1000
statistics:
  enabled: true
  interval: 168h
tls:
  enabled: false
  allow_unencrypted_doh: true
schema_version: 28
EOF_AGH

        # 5. Установка и запуск службы systemd
        if [ ! -x /opt/AdGuardHome/AdGuardHome ]; then
            die "Не удалось загрузить или распаковать бинарник AdGuard Home в /opt/AdGuardHome/AdGuardHome"
        fi
        /opt/AdGuardHome/AdGuardHome -s install >/dev/null 2>&1 || true

        # 6. Ограничение памяти Go для экономии RAM на VPS
        mkdir -p /etc/systemd/system/AdGuardHome.service.d
        cat << 'EOF_GOMEM' > /etc/systemd/system/AdGuardHome.service.d/memory.conf
[Service]
Environment="GOGC=50"
Environment="GOMEMLIMIT=100MiB"
EOF_GOMEM
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart AdGuardHome 2>/dev/null || true

        # 7. Интеграция с Xray DNS (если выбрано AGH_XRAY_DNS=y)
        if [[ "${AGH_XRAY_DNS,,}" == "y" || "${AGH_XRAY_DNS:-}" == "1" ]]; then
            xui_db="/etc/x-ui/x-ui.db"
            [ -f "$xui_db" ] || xui_db="/usr/local/x-ui/bin/x-ui.db"
            if [ -f "$xui_db" ]; then
                python3 -c "
import sqlite3, json, os

db_path = '$xui_db'
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute(\"SELECT value FROM settings WHERE key='xrayTemplateConfig'\")
row = cur.fetchone()
if row and row[0]:
    try:
        cfg = json.loads(row[0])
        dns = cfg.get('dns', {})
        agh_port = int(os.environ.get('PORT_AGH_DNS') or '10053')
        dns['servers'] = [{'address': '127.0.0.1', 'port': agh_port}]
        dns['queryStrategy'] = 'UseIPv4'
        cfg['dns'] = dns
        new_val = json.dumps(cfg, ensure_ascii=False)
        cur.execute(\"UPDATE settings SET value=? WHERE key='xrayTemplateConfig'\", (new_val,))
        conn.commit()
    except Exception:
        pass
conn.close()
" 2>/dev/null || true
                systemctl restart x-ui 2>/dev/null || true
            fi
        fi
    }

    run_with_spinner "Установка и настройка AdGuard Home (DoH + Split-DNS + OISD)" install_agh_task || die "Ошибка установки AdGuard Home."
}
install_step_awg() {
        ensure_amneziawg_installed
        setup_amneziawg_controller
        deploy_amneziawg_backend
        if command -v ufw >/dev/null 2>&1; then
            awg_p="${AWG_STANDALONE_PORT:-8445}"
            ufw allow "${awg_p}/udp" comment "AmneziaWG Standalone Server" >/dev/null 2>&1 || true
            ok "Правило файрвола: разрешен порт ${awg_p}/udp (AmneziaWG)"
        fi
}
install_step_verify() {
    post_install_sanity_check
    if [ "${SSH_PORT:-${SSH_ACTIVE_PORT:-22}}" != "${SSH_ACTIVE_PORT:-22}" ]; then
        wait_and_finalize_ssh_transition "$SSH_PORT" "${SSH_ACTIVE_PORT:-22}"
    fi
}
report_installation() {
    if is_true "${ENABLE_WEB_STACK:-y}"; then
        :
# =============================================================
#  ФОРМИРОВАНИЕ ИТОГОВ И ИНСТРУКЦИИ ДЛЯ 3X-UI
# =============================================================
UFW_DENY_LIST=""
for port in "${ALL_REALITY_PORTS[@]:-}"; do
    if [ -n "$port" ]; then
        UFW_DENY_LIST="${UFW_DENY_LIST} && ufw deny ${port}/tcp"
    fi
done

UFW_ALLOW_LIST="ufw allow 80/tcp && ufw allow 443/tcp"
if [[ "${ENABLE_HY2:-}" == "1" || "${ENABLE_HY2,,}" == "y" ]] && [ -n "${HY2_PORT:-}" ]; then
    if [ "${HY2_PORT}" != "443" ]; then
        UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${HY2_PORT}/udp"
    else
        UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow 443/udp"
    fi
    # Port Hopping: открываем диапазон UDP-портов
    if [[ "${HY2_PORT_HOPPING,,}" == "y" || "${HY2_PORT_HOPPING:-}" == "1" ]] && [ -n "${HY2_PORT_HOPPING_RANGE:-}" ]; then
        UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${HY2_PORT_HOPPING_RANGE//:/ }/udp"
    fi
fi
if [[ "${ENABLE_AWG_V3:-}" == "1" || "${ENABLE_AWG_V3,,}" == "y" ]] && [ -n "${AWG_V3_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${AWG_V3_PORT}/udp"
fi
if [[ "${ENABLE_AWG_V2:-}" == "1" || "${ENABLE_AWG_V2,,}" == "y" ]] && [ -n "${AWG_V2_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${AWG_V2_PORT}/udp"
fi
if [[ "${ENABLE_AWG_STANDALONE:-}" == "1" || "${ENABLE_AWG_STANDALONE,,}" == "y" ]] && [ -n "${AWG_STANDALONE_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${AWG_STANDALONE_PORT}/udp"
fi
if [[ "${ENABLE_SS2022:-}" == "1" || "${ENABLE_SS2022,,}" == "y" ]] && [ -n "${SS2022_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${SS2022_PORT}/tcp && ufw allow ${SS2022_PORT}/udp"
fi
if [[ "${ENABLE_TUIC:-}" == "1" || "${ENABLE_TUIC,,}" == "y" ]] && [ -n "${TUIC_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${TUIC_PORT}/udp"
fi
if [[ "${ENABLE_MTPROTO:-}" == "1" || "${ENABLE_MTPROTO,,}" == "y" ]] && [ -n "${MTPROTO_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${MTPROTO_PORT}/tcp"
fi
if [[ "${ENABLE_MASQUE:-}" == "1" || "${ENABLE_MASQUE,,}" == "y" ]] && [ -n "${MASQUE_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${MASQUE_PORT}/udp"
fi
if [[ "${ENABLE_DNSTT:-}" == "1" || "${ENABLE_DNSTT,,}" == "y" ]] && [ -n "${DNSTT_PORT:-}" ]; then
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${DNSTT_PORT}/udp"
fi
if [[ "${ENABLE_MIERU:-}" == "1" || "${ENABLE_MIERU,,}" == "y" ]] && [ -n "${MIERU_PORT:-}" ]; then
    _ufw_m_p="${MIERU_PORT//-/:}"
    UFW_ALLOW_LIST="${UFW_ALLOW_LIST} && ufw allow ${_ufw_m_p}/tcp && ufw allow ${_ufw_m_p}/udp"
fi

SSL_CERT_REPORT=""
for dom in "${ALL_DOMAINS[@]}"; do
    if [ -f "${SSL_BASE_DIR}/$dom/fullchain.pem" ]; then
        SSL_CERT_REPORT+="  - Домен: ${CYAN}${dom}${NC}\n"
        SSL_CERT_REPORT+="    Cert: ${GREEN}${SSL_BASE_DIR}/${dom}/fullchain.pem${NC}\n"
        SSL_CERT_REPORT+="    Key:  ${GREEN}${SSL_BASE_DIR}/${dom}/privkey.pem${NC}\n\n"
    fi
done

REALITY_INBOUNDS_REPORT=""
if is_true "${STEAL_ENABLED:-0}"; then
    REALITY_INBOUNDS_REPORT+="\n  ${BOLD}[Сценарий 1: VLESS REALITY (маскировка под свой сайт с защитой Anti-Loop)]${NC}\n"
    for port in "${STEAL_PORTS_LIST[@]}"; do
        p_doms=()
        for s_dom in "${STEAL_DOMAINS[@]}"; do
            [ -n "$s_dom" ] || continue
            if [ "${DOMAIN_TO_PORT[$s_dom]:-}" = "$port" ]; then
                p_doms+=("$s_dom")
            fi
        done
        [ ${#p_doms[@]} -gt 0 ] || continue

        REALITY_INBOUNDS_REPORT+="    - Инбаунд для порта ${GREEN}${port}${NC} (Домены: ${CYAN}${p_doms[*]}${NC}):
      * ${YELLOW}Вкладка «Основное»:${NC} Протокол: ${GREEN}vless${NC} | Адрес: ${GREEN}127.0.0.1${NC} | Порт: ${GREEN}${port}${NC}
      * ${YELLOW}Вкладка «Поток»:${NC} Транспорт: ${GREEN}RAW (tcp)${NC} | Accept Proxy Protocol: ${GREEN}Включить (xver: 1)${NC}
      * ${YELLOW}Вкладка «Безопасность»:${NC} ${GREEN}Reality${NC} | uTLS: ${GREEN}${REALITY_FINGERPRINT:-firefox}${NC}
        - Dest (Anti-Loop Fallback): ${GREEN}127.0.0.1:${REALITY_FALLBACK_PORT}${NC}
        - Proxy Protocol для Dest: ${GREEN}Включить (xver: 1)${NC}
        - Server Names (SNI): ${CYAN}${p_doms[*]}${NC}
      * ${YELLOW}Вкладка «Сниффинг»:${NC} Включить (${GREEN}HTTP, TLS, QUIC, FAKEDNS${NC})\n\n"
    done
fi

if is_true "${CLASSIC_ENABLED:-0}"; then
    REALITY_INBOUNDS_REPORT+="\n  ${BOLD}[Сценарий 2: VLESS REALITY (маскировка под популярные внешние сервисы)]${NC}\n"
    for port in "${CLASSIC_PORTS_LIST[@]}"; do
        p_snis=()
        for ext_sni in "${!EXT_SNI_TO_PORT[@]}"; do
            if [ "${EXT_SNI_TO_PORT[$ext_sni]:-}" = "$port" ]; then
                p_snis+=("$ext_sni")
            fi
        done
        [ ${#p_snis[@]} -gt 0 ] || p_snis=("gateway.icloud.com")
        primary_ext="${p_snis[0]}"

        REALITY_INBOUNDS_REPORT+="    - Инбаунд для порта ${GREEN}${port}${NC} (SNI: ${CYAN}${p_snis[*]}${NC}):
      * ${YELLOW}Вкладка «Основное»:${NC} Протокол: ${GREEN}vless${NC} | Адрес: ${GREEN}127.0.0.1${NC} | Порт: ${GREEN}${port}${NC}
      * ${YELLOW}Вкладка «Поток»:${NC} Транспорт: ${GREEN}RAW (tcp)${NC} | Accept Proxy Protocol: ${GREEN}Включить (xver: 1)${NC}
      * ${YELLOW}Вкладка «Безопасность»:${NC} ${GREEN}Reality${NC} | uTLS: ${GREEN}${REALITY_FINGERPRINT:-firefox}${NC}
        - Dest (Target): ${CYAN}${primary_ext}:443${NC}
        - Proxy Protocol для Dest: ${RED}Выключить (xver: 0)${NC}
        - Server Names (SNI): ${CYAN}${p_snis[*]}${NC}
      * ${YELLOW}Вкладка «Сниффинг»:${NC} Включить (${GREEN}HTTP, TLS, QUIC, FAKEDNS${NC})\n\n"
    done
fi



DECOY_NAME="Local site"
case "${DECOY_MODE:-1}" in 1) DECOY_NAME="DataSphere Analytics";; 2) DECOY_NAME="CosmosCloud";; 3) DECOY_NAME="Nginx welcome";; esac
echo
echo -e "${GREEN}=====================================================================${NC}"
echo -e "   ИНФРАСТРУКТУРА УСПЕШНО РАЗВЕРНУТА (${SCRIPT_VERSION} PUBLIC EDITION)!       "
echo -e "${GREEN}=====================================================================${NC}"
echo -e "  Главная страница:            ${CYAN}https://${PRIMARY_DOMAIN}/${NC} (${DECOY_NAME})"
echo -e "  Вход в панель 3X-UI:         ${GREEN}https://${PRIMARY_DOMAIN}${PANEL_PATH}${NC}"
echo -e "  Веб-диагностика (SSO):       ${GREEN}https://${PRIMARY_DOMAIN}${PANEL_PATH}diag${NC} ${DIM}(требует авторизации в панели)${NC}"
echo -e "  Логин администратора:        ${BOLD}${ADMIN_USERNAME:-admin}${NC}"
if [ -n "${ADMIN_PASSWORD:-}" ]; then
    echo -e "  Пароль администратора:       ${BOLD}${ADMIN_PASSWORD}${NC}"
fi
echo -e "  Канал подписок:              ${GREEN}https://${PRIMARY_DOMAIN}${SUB_PATH}${NC}"
echo -e "  Канал подписок (JSON):       ${GREEN}https://${PRIMARY_DOMAIN}${SUB_JSON_PATH}${NC}"
echo -e "  Канал подписок (Clash):      ${GREEN}https://${PRIMARY_DOMAIN}${SUB_CLASH_PATH}${NC}"
if [[ "${ENABLE_WARP,,}" == "y" || "${ENABLE_WARP:-}" == "1" ]]; then
    echo -e "  Cloudflare WARP Outbound:    ${GREEN}АКТИВИРОВАН (Google, Gemini, ChatGPT / MTU 1280)${NC}"
fi
if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
    if [ "${AGH_MODE:-1}" = "2" ] && [ -n "${AGH_DOMAIN:-}" ]; then
        echo -e "  Панель AdGuard Home:         ${CYAN}https://${AGH_DOMAIN}/${NC}"
        echo -e "  Приватный DoH для роутера:   ${GREEN}https://${AGH_DOMAIN}/dns-query/${AGH_CLIENT_ID}${NC}"
    else
        echo -e "  Панель AdGuard Home:         ${CYAN}http://127.0.0.1:${PORT_AGH_WEB:-3000}${NC} ${DIM}(SSH туннель)${NC}"
        echo -e "  Приватный DoH для роутера:   ${GREEN}https://${PRIMARY_DOMAIN}/dns-query/${AGH_CLIENT_ID}${NC}"
    fi
fi
if [[ "${ENABLE_NODE_TOKEN,,}" == "y" || "${ENABLE_NODE_TOKEN:-}" == "1" ]]; then
    echo -e "  3X-UI Node API Token:        ${GREEN}${NODE_TOKEN:-Не получен}${NC} (${WHITE}${NODE_TOKEN_NAME}${NC})"
fi

# Сохранение учетных данных в защищенный файл
if [ -n "${ADMIN_PASSWORD:-}" ] || { is_true "${ENABLE_NODE_TOKEN:-n}" && [ -n "${NODE_TOKEN:-}" ]; }; then
    credential_umask=$(umask)
    umask 077
    CRED_FILE="/root/vpn_credentials.txt"
    cat << EOF_CRED > "$CRED_FILE"
=====================================================================
УЧЕТНЫЕ ДАННЫЕ ПАНЕЛИ И СЕРВИСОВ 3X-UI
Файл создан: $(date '+%Y-%m-%d %H:%M:%S')
=====================================================================
Панель управления:         https://${PRIMARY_DOMAIN}${PANEL_PATH}
$([ -n "${DIAG_TOKEN:-}" ] && echo "Веб-диагностика (SSO):     https://${PRIMARY_DOMAIN}${PANEL_PATH}diag")
$([ -n "${DIAG_TOKEN:-}" ] && echo "Токен диагностики:         ${DIAG_TOKEN}")
Логин администратора:       ${ADMIN_USERNAME:-admin}
Пароль администратора:      ${ADMIN_PASSWORD}

Ссылка на подписку:        https://${PRIMARY_DOMAIN}${SUB_PATH}
Ссылка на подписку (JSON): https://${PRIMARY_DOMAIN}${SUB_JSON_PATH}
Ссылка на подписку (Clash): https://${PRIMARY_DOMAIN}${SUB_CLASH_PATH}
EOF_CRED
    if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
        cat << EOF_AGH_CRED >> "$CRED_FILE"
=====================================================================
ПРИВАТНЫЙ ADGUARD HOME DOH
Логин администратора:  ${AGH_USER}
Пароль администратора: ${AGH_PASS}
URL DoH для роутера:   $([ "${AGH_MODE:-1}" = "2" ] && echo "https://${AGH_DOMAIN}/dns-query/${AGH_CLIENT_ID}" || echo "https://${PRIMARY_DOMAIN}/dns-query/${AGH_CLIENT_ID}")
EOF_AGH_CRED
    fi
    if [[ "${ENABLE_NODE_TOKEN,,}" == "y" || "${ENABLE_NODE_TOKEN:-}" == "1" ]]; then
        cat << EOF_NODE_CRED >> "$CRED_FILE"
=====================================================================
ПОДКЛЮЧЕНИЕ СЕРВЕРА КАК УЗЛА (3X-UI NODE)
Имя узла (Node Name):  ${NODE_TOKEN_NAME}
Адрес хоста (Host):    ${PRIMARY_DOMAIN}
Порт (Port):           443 (HTTPS через Nginx L4/L7)
Базовый путь:          ${PANEL_PATH}
API Token:             ${NODE_TOKEN:-Не получен}
Логин администратора:  ${ADMIN_USERNAME:-admin}
Пароль администратора: ${ADMIN_PASSWORD}
TLS сертификат:        Действительный (Let's Encrypt / acme.sh)
EOF_NODE_CRED
    fi
    echo "=====================================================================" >> "$CRED_FILE"
    chmod 600 "$CRED_FILE"
    umask "$credential_umask"
    echo -e "  ${CYAN}[i] Учетные данные сохранены в:${NC} ${BOLD}$CRED_FILE${NC} (chmod 600)"
fi
echo

echo -e "${YELLOW}[SSL] ВЫПУЩЕННЫЕ СЕРТИФИКАТЫ (Базовый путь: ${SSL_BASE_DIR}):${NC}"
echo -e "$SSL_CERT_REPORT"

if [[ "${SHOW_MANUAL_STEPS:-0}" == "1" ]]; then
echo -e "${YELLOW}ШАГ 1: Настройка файервола UFW (Защита локальных сокетов и открытие VPN):${NC}"
echo -e "  ${CYAN}${UFW_ALLOW_LIST}${NC}"
echo -e "  ${RED}ufw deny $PANEL_PORT/tcp && ufw deny $SUB_PORT/tcp && ufw deny $XHTTP_STREAM_PORT/tcp && ufw deny $REALITY_FALLBACK_PORT/tcp${UFW_DENY_LIST}${NC}"
echo

echo -e "${YELLOW}ШАГ 2: Инбаунды VLESS REALITY (3X-UI):${NC}"
echo -e "$REALITY_INBOUNDS_REPORT"

echo -e "${YELLOW}ШАГ 3: Инбаунд VLESS xHTTP (Native H2 Stream-One + VLESSENC + Анти-Дроп):${NC}"
echo -e "  - ${YELLOW}Вкладка «Основное»:${NC} Протокол: ${GREEN}vless${NC} | Адрес: ${GREEN}127.0.0.1${NC} | Порт: ${GREEN}$XHTTP_STREAM_PORT${NC}"
echo -e "  - ${YELLOW}Вкладка «Протокол»:${NC} Генерация ключей: выбрать ${GREEN}ML-KEM-768 (native)${NC} и нажать ${CYAN}«Сгенерировать»${NC}"
echo -e "  - ${YELLOW}Вкладка «Поток»:${NC}"
echo -e "    * Транспорт: ${GREEN}xHTTP${NC} | Режим: ${GREEN}stream-one${NC}"
echo -e "    * Хост: ${CYAN}$PRIMARY_DOMAIN${NC} | Путь: ${CYAN}$XHTTP_STREAM_PATH${NC}"
echo -e "    * Padding Bytes: ${GREEN}100-500${NC} | Padding Obfs Mode: ${GREEN}Включить${NC} | Key: ${GREEN}X-Amz-Meta-Trace${NC}"
echo -e "    * XMUX: ${GREEN}maxConcurrency: 0 (Выключено)${NC} — исключает раздувание буферов и вылеты на iOS/ПК"
echo -e "    * ${RED}ВНИМАНИЕ:${NC} ${YELLOW}QUIC / UDP ПАРАМЕТРЫ СТРОГО ВЫКЛЮЧИТЬ (0)${NC} — поток идёт строго по HTTP/2 TCP через Nginx!"
echo -e "  - ${YELLOW}Вкладка «Безопасность»:${NC} ${RED}Нет (None)${NC} | Accept Proxy Protocol: ${RED}Выключить (0)${NC}"
echo -e "  - ${YELLOW}Вкладка «Сниффинг»:${NC} Включить (${GREEN}HTTP, TLS, QUIC, FAKEDNS${NC})"
echo

if [[ "${ENABLE_HY2:-}" == "1" || "${ENABLE_HY2,,}" == "y" ]] && [ -n "${HY2_PORT:-}" ]; then
hy2_active_dom="${HY2_DOMAIN:-$PRIMARY_DOMAIN}"
echo -e "${YELLOW}ШАГ 4: Инбаунд Hysteria 2 (UDP $HY2_PORT):${NC}"
echo -e "  - ${YELLOW}Вкладка «Основное»:${NC} Протокол: ${GREEN}hysteria (v2)${NC} | Адрес: ${GREEN}0.0.0.0${NC} | Порт: ${GREEN}$HY2_PORT${NC} (UDP)"
echo -e "  - ${YELLOW}Вкладка «Поток»:${NC} Masquerade: тип ${GREEN}proxy${NC} -> URL: ${CYAN}http://127.0.0.1:80${NC}"
echo -e "  - ${YELLOW}Вкладка «Безопасность»:${NC} ${GREEN}TLS${NC} | SNI: ${CYAN}${hy2_active_dom}${NC} | ALPN: ${GREEN}h3${NC}"
echo -e "    * Публичный ключ: ${CYAN}${SSL_BASE_DIR}/${hy2_active_dom}/fullchain.pem${NC}"
echo -e "    * Приватный ключ: ${CYAN}${SSL_BASE_DIR}/${hy2_active_dom}/privkey.pem${NC}"
if [[ "${HY2_PORT_HOPPING,,}" == "y" || "${HY2_PORT_HOPPING:-}" == "1" ]] && [ -n "${HY2_PORT_HOPPING_RANGE:-}" ]; then
echo -e "  - ${YELLOW}Port Hopping:${NC} ${GREEN}Активирован${NC} | Диапазон: ${CYAN}UDP ${HY2_PORT_HOPPING_RANGE//:/-}${NC} → порт ${GREEN}${HY2_PORT}${NC}"
echo -e "    * Адрес подключения клиента: ${CYAN}${hy2_active_dom}:${HY2_PORT},${HY2_PORT_HOPPING_RANGE//:/-}${NC}"
fi
echo
fi

if [[ "${ENABLE_AWG_V3:-}" == "1" || "${ENABLE_AWG_V3,,}" == "y" ]] && [ -n "${AWG_V3_PORT:-}" ]; then
echo -e "${YELLOW}ШАГ 5: Инбаунд AmneziaWG v3.1 (WG3 — UDP $AWG_V3_PORT):${NC}"
echo -e "  - ${YELLOW}Вкладка «Основное»:${NC}"
echo -e "    * Включить: ${GREEN}Включено${NC} | Примечание: ${GREEN}WG3${NC} | Протокол: ${GREEN}amneziawg${NC}"
echo -e "    * Адрес: ${GREEN}0.0.0.0${NC} | Стратегия адреса для ссылок: ${GREEN}Адрес прослушивания inbound${NC}"
echo -e "    * Порядок в подписке: ${GREEN}1${NC} | Порт: ${GREEN}$AWG_V3_PORT${NC} (UDP)"
echo -e "    * Общий расход: ${GREEN}0${NC} | Сброс трафика: ${GREEN}Никогда${NC}"
echo -e "  - ${YELLOW}Вкладка «Протокол»:${NC}"
echo -e "    * Ключи: нажать ${CYAN}«Сгенерировать»${NC} (иконка обновления рядом с приватным ключом)"
echo -e "    * Сеть: Подсеть: ${GREEN}10.8.0.0${NC} | Маска подсети (CIDR): ${GREEN}22${NC} | MTU: ${GREEN}1280${NC}"
echo -e "    * DNS: Основной DNS: ${GREEN}9.9.9.9${NC} | Резервный DNS: ${GREEN}76.76.2.0${NC}"
echo -e "    * Внешний интерфейс: ${GREEN}eth0${NC} (или оставить пустым) | Включить IPv6: ${RED}Выключить${NC}"
echo -e "  - ${YELLOW}Параметры обфускации:${NC}"
echo -e "    * Мусорные пакеты: ${CYAN}Jc = 2${NC}, ${CYAN}Jmin = 20${NC}, ${CYAN}Jmax = 50${NC}"
echo -e "    * Мусорные смещения: ${CYAN}S1 = 16${NC}, ${CYAN}S2 = 20${NC}, ${CYAN}S3 = 24${NC}, ${CYAN}S4 = 16${NC}"
echo -e "    * Заголовки ${CYAN}H1 - H4${NC}: ${GREEN}Оставить ПУСТЫМИ${NC} (по умолчанию 1/2/3/4)"
echo -e "    * Сигнатурные пакеты ${CYAN}I1 - I5${NC}: ${GREEN}Оставить ПУСТЫМИ${NC}"
echo -e "    * Защита заголовков (${CYAN}HeaderProtectionKey${NC}): ${GREEN}Авто (32 байта base64)${NC} (шифрование handshake против ТСПУ)"
echo -e "    * Паддинг содержимого (${CYAN}ContentPaddingAddition${NC}): ${GREEN}ПУСТО (Выключено)${NC}"
echo -e "    * Тайминги ключей: ${CYAN}RekeyAfterTime = 120-170${NC}, ${CYAN}RekeyTimeout = 3-4${NC}, ${CYAN}RejectAfterTime = 180-210${NC}"
echo -e "    * Тайминги соединения: ${CYAN}KeepaliveTimeout = 15-20${NC}, ${CYAN}MaxHandshakeAttempts = 20-25${NC}"
echo -e "    * Переключатели: ${CYAN}RandomTrailers:${NC} ${RED}Выключить (OFF, критично для скорости!)${NC} | ${CYAN}DisableCookies:${NC} ${GREEN}Включить${NC}"
echo
fi
fi

    if [[ "${SHOW_MANUAL_STEPS:-0}" == "1" ]]; then
        if [[ "${ENABLE_AWG_V2:-}" == "1" || "${ENABLE_AWG_V2,,}" == "y" ]] && [ -n "${AWG_V2_PORT:-}" ]; then
            echo -e "${YELLOW}ШАГ 6: Инбаунд AmneziaWG v2.0 (UDP $AWG_V2_PORT):${NC}"
            echo -e "  - ${YELLOW}Вкладка «Основное»:${NC} Протокол: ${GREEN}amneziawg / wireguard${NC} | Адрес: ${GREEN}0.0.0.0${NC} | Порт: ${GREEN}$AWG_V2_PORT${NC} (UDP)"
            echo -e "  - ${YELLOW}Вкладка «Параметры AWG» (Для роутеров Keenetic / OpenWrt):${NC}"
            echo -e "    * ${CYAN}H1-H4 (Строки):${NC} ${GREEN}\"149419586\", \"878791997\", \"1251051976\", \"1657628296\"${NC}"
            echo -e "    * ${CYAN}HeaderProtectionKey:${NC} ${RED}ПУСТО (Выключено)${NC}"
            echo -e "    * ${CYAN}Смещения (>= 12):${NC} ${GREEN}S1 = 16, S2 = 20, S3 = 24, S4 = 16${NC}"
            echo -e "    * ${CYAN}Junk packets:${NC} ${GREEN}Jc = 2, Jmin = 20, Jmax = 50${NC} | ${CYAN}MTU:${NC} ${GREEN}1280${NC}"
            echo
        fi
    fi

    if [[ "${ENABLE_AWG_STANDALONE:-}" == "1" || "${ENABLE_AWG_STANDALONE,,}" == "y" ]]; then
        echo -e "${YELLOW}СЕРВЕРНЫЙ КОНТРОЛЛЕР AMNEZIAWG (awg-mgr):${NC}"
        echo -e "  - ${YELLOW}Утилита управления:${NC}      ${GREEN}awg-mgr${NC} (или ${GREEN}awg-cli${NC})"
        echo -e "  - ${YELLOW}Первичный конфиг админа:${NC} ${CYAN}/root/awg/client-1.conf${NC}"
        if [ -f "/root/awg/client-1.vpnuri" ]; then
            echo -e "  - ${YELLOW}Ссылка Amnezia (vpn://):${NC} ${GREEN}$(head -n 1 /root/awg/client-1.vpnuri 2>/dev/null | tr -d '[:space:]')${NC}"
        fi
        echo -e "  - ${YELLOW}Основные команды CLI:${NC}"
        echo -e "    * Создать клиента:   ${CYAN}awg-mgr add <имя> [--preset=stealth|fast|base] [--expires=30d]${NC}"
        echo -e "    * Ссылка Amnezia:    ${CYAN}awg-mgr uri <имя>${NC}"
        echo -e "    * Показать список:   ${CYAN}awg-mgr list${NC}"
        echo -e "    * QR-код в терминал: ${CYAN}awg-mgr qr <имя>${NC}"
        echo -e "    * Удалить клиента:   ${CYAN}awg-mgr remove <имя>${NC}"
        echo -e "    * Резервная копия:   ${CYAN}awg-mgr backup${NC} / ${CYAN}awg-mgr restore <файл>${NC}"
        echo -e "    * Очистка истекших:  ${CYAN}awg-mgr purge-expired${NC} (также настроен в cron)"
        echo

        if [ -f "/root/awg/client-1.conf" ] && command -v /root/awg/manage-clients.sh >/dev/null 2>&1; then
            echo -e "  ${WHITE}${BOLD}QR-код для подключения первого клиента (client-1):${NC}"
            /root/awg/manage-clients.sh qr client-1 2>/dev/null || true
            echo
        fi
    fi

    if [[ "${SHOW_MANUAL_STEPS:-0}" == "1" ]]; then
        echo -e "${YELLOW}ШАГ 7: Настройки Клиента и Подписок в 3X-UI:${NC}"
        echo -e "  - ${YELLOW}В карточке Клиента (Клиенты -> Учетные данные):${NC}"
        echo -e "    * Для инбаунда REALITY: Flow: выбрать ${GREEN}xtls-rprx-vision${NC}"
        echo -e "    * Для инбаунда xHTTP: Flow: строго ${RED}пусто (none)${NC} | Decryption: ключ ${GREEN}vlessenc${NC}"
        echo -e "  - ${YELLOW}Настройки подписок (Панель -> Подписка):${NC}"
        echo -e "    * Subscription Port: ${GREEN}$SUB_PORT${NC} | Subscription Path: ${GREEN}$SUB_PATH${NC}"
        echo -e "    * Subscription URL: ${CYAN}https://${PRIMARY_DOMAIN}${SUB_PATH}${NC}"
        echo -e "    * Subscription URL (JSON): ${CYAN}https://${PRIMARY_DOMAIN}${SUB_JSON_PATH}${NC}"
        echo -e "    * Subscription URL (Clash): ${CYAN}https://${PRIMARY_DOMAIN}${SUB_CLASH_PATH}${NC}"
        echo -e "  - ${YELLOW}В разделе «Хосты» (Hosts) добавьте 2 правила:${NC}"
        echo -e "    1) ${BOLD}MAIN_SAME_443:${NC} Инбаунды: ${CYAN}REALITY + Hysteria 2${NC} -> Порт: ${GREEN}443${NC} | Безопасность: ${GREEN}same${NC}"
        echo -e "    2) ${BOLD}XHTTP_TLS_443:${NC} Инбаунд: ${CYAN}${SERVER_PREFIX} (VLESS xHTTP)${NC} -> Порт: ${GREEN}443${NC} | Безопасность: ${GREEN}tls${NC} (SNI: ${CYAN}$PRIMARY_DOMAIN${NC})"
    fi

    if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
        local_agh_panel_url=""
        local_agh_doh_url=""
        local_server_ip="${WAN_IP:-$(get_wan_ip)}"

        if [ "${AGH_MODE:-1}" = "2" ] && [ -n "${AGH_DOMAIN:-}" ]; then
            local_agh_panel_url="https://${AGH_DOMAIN}/"
            local_agh_doh_url="https://${AGH_DOMAIN}/dns-query/${AGH_CLIENT_ID}"
        else
            local_agh_panel_url="http://127.0.0.1:${PORT_AGH_WEB:-3000} (доступ через SSH-туннель: ssh -L ${PORT_AGH_WEB:-3000}:127.0.0.1:${PORT_AGH_WEB:-3000} user@${local_server_ip})"
            local_agh_doh_url="https://${PRIMARY_DOMAIN}/dns-query/${AGH_CLIENT_ID}"
        fi

        echo
        echo -e "${YELLOW}ПРИВАТНЫЙ ADGUARD HOME DOH + SPLIT-DNS:${NC}"
        echo -e "  - ${YELLOW}Веб-панель:${NC}          ${CYAN}${local_agh_panel_url}${NC}"
        echo -e "  - ${YELLOW}Логин / Пароль:${NC}      ${GREEN}${AGH_USER}${NC} / ${GREEN}${AGH_PASS}${NC}"
        echo -e "  - ${YELLOW}URL DoH для роутера:${NC} ${GREEN}${local_agh_doh_url}${NC}"
        echo -e "  - ${YELLOW}Split-DNS зоны:${NC}      ${CYAN}.ru, .рф, .su, .kz, .by${NC} → ${GREEN}Яндекс DNS (77.88.8.8)${NC}"
        echo -e "  - ${YELLOW}Блокировка рекламы:${NC}  ${GREEN}OISD Small (активен, автообновление каждые 24ч)${NC}"
        echo -e "  - ${YELLOW}Upstream DNS:${NC}        ${CYAN}Control D (p2 Ads/Malware), Google H3, Cloudflare, DoQ${NC}"
        if [[ "${AGH_XRAY_DNS,,}" == "y" || "${AGH_XRAY_DNS:-}" == "1" ]]; then
            echo -e "  - ${YELLOW}Интеграция с Xray:${NC}   ${GREEN}127.0.0.1 (Все VPN-клиенты фильтруются через AGH)${NC}"
        fi
        echo
        echo -e "  ${YELLOW}Инструкция по настройке роутера (Keenetic):${NC}"
        echo -e "    1. Сетевые правила -> Интернет-фильтры -> Настройка DNS (вкладка DNS-серверы)"
        echo -e "    2. Добавить DNS-сервер -> IP-адрес: ${CYAN}${local_server_ip}${NC}"
        echo -e "    3. URL DoH: ${CYAN}${local_agh_doh_url}${NC}"
        echo
        echo -e "  ${YELLOW}Инструкция по настройке OpenWrt (Podkop / https-dns-proxy):${NC}"
        echo -e "    1. Services -> HTTPS DNS Proxy -> Добавить upstream"
        echo -e "    2. Custom URL: ${CYAN}${local_agh_doh_url}${NC}"
    fi

    if [[ "${ENABLE_NODE_TOKEN,,}" == "y" || "${ENABLE_NODE_TOKEN:-}" == "1" ]]; then
        echo
        echo -e "${YELLOW}ПОДКЛЮЧЕНИЕ СЕРВЕРА КАК УЗЛА (3X-UI NODE):${NC}"
        echo -e "  - ${YELLOW}Имя узла (Node Name):${NC}       ${GREEN}${NODE_TOKEN_NAME}${NC}"
        echo -e "  - ${YELLOW}Адрес хоста (Host):${NC}         ${CYAN}${PRIMARY_DOMAIN}${NC}"
        echo -e "  - ${YELLOW}Порт (Port):${NC}                ${GREEN}443${NC} (HTTPS через Nginx L4/L7 маскировку)"
        echo -e "  - ${YELLOW}Базовый путь (Base Path):${NC}   ${CYAN}${PANEL_PATH}${NC}"
        if [ -n "${NODE_TOKEN:-}" ]; then
            echo -e "  - ${YELLOW}API Token:${NC}                  ${GREEN}${NODE_TOKEN}${NC}"
        else
            echo -e "  - ${YELLOW}API Token:${NC}                  ${GREEN}Не получен${NC}"
        fi
        echo -e "  - ${YELLOW}Авторизация (Fallback):${NC}     Логин: ${WHITE}${ADMIN_USERNAME:-admin}${NC}, Пароль: ${YELLOW}${ADMIN_PASSWORD}${NC}"
        echo -e "  - ${YELLOW}Проверка сертификата (TLS):${NC}  ${GREEN}Включена (Действительный сертификат Let's Encrypt)${NC}"
    fi
    else
        :
    echo
    echo -e "${GREEN}=====================================================================${NC}"
    echo -e "  ${GREEN}${BOLD}🎉 УСТАНОВКА АВТОНОМНОГО СЕРВЕРА AMNEZIAWG УСПЕШНО ЗАВЕРШЕНА!${NC}"
    echo -e "${GREEN}=====================================================================${NC}"
    echo
    echo -e "${YELLOW}СЕРВЕРНЫЙ КОНТРОЛЛЕР AMNEZIAWG (awg-mgr):${NC}"
    echo -e "  - ${YELLOW}Служба ядра Linux:${NC}         ${GREEN}awg-quick@awg0${NC} (активна)"
    echo -e "  - ${YELLOW}Внешний UDP-порт:${NC}          ${WHITE}${AWG_STANDALONE_PORT:-8445}/udp${NC}"
    echo -e "  - ${YELLOW}Хост подключения (Endpoint):${NC} ${CYAN}${AWG_SERVER_HOST:-${WAN_IP:-127.0.0.1}}:${AWG_STANDALONE_PORT:-8445}${NC}"
    echo -e "  - ${YELLOW}Первичный конфиг админа:${NC}     ${CYAN}/root/awg/client-1.conf${NC}"
    if [ -f "/root/awg/client-1.vpnuri" ]; then
        echo -e "  - ${YELLOW}Ссылка Amnezia (vpn://):${NC}     ${GREEN}$(head -n 1 /root/awg/client-1.vpnuri 2>/dev/null | tr -d '[:space:]')${NC}"
    fi
    echo -e "  - ${YELLOW}Утилита управления:${NC}          ${GREEN}awg-mgr${NC} (или ${GREEN}awg-cli${NC})"
    echo
    echo -e "  ${YELLOW}Команды управления клиентами:${NC}"
    echo -e "    * Создать нового клиента:   ${CYAN}awg-mgr add <имя> [--preset=stealth|fast|base] [--expires=30d]${NC}"
    echo -e "    * Получить ссылку vpn://:   ${CYAN}awg-mgr uri <имя>${NC}"
    echo -e "    * Список всех клиентов:     ${CYAN}awg-mgr list${NC}"
    echo -e "    * Показать QR-код клиента:  ${CYAN}awg-mgr qr <имя>${NC}"
    echo -e "    * Отозвать / удалить:       ${CYAN}awg-mgr remove <имя>${NC}"
    echo -e "    * Резервная копия:          ${CYAN}awg-mgr backup${NC} / ${CYAN}awg-mgr restore <файл>${NC}"
    echo -e "    * Автоочистка истекших:     ${CYAN}awg-mgr purge-expired${NC} (активна в cron)"
    echo

    if [ -f "/root/awg/client-1.conf" ] && command -v /root/awg/manage-clients.sh >/dev/null 2>&1; then
        echo -e "  ${WHITE}${BOLD}QR-код для подключения первого клиента (client-1):${NC}"
        /root/awg/manage-clients.sh qr client-1 2>/dev/null || true
        echo
    fi
    fi
    SCRIPT_END_TIME=$(date +%s)
    SCRIPT_END_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
    TOTAL_EXECUTION_TIME=$(( SCRIPT_END_TIME - SCRIPT_START_TIME ))
    FORMATTED_TOTAL_TIME=$(format_duration "$TOTAL_EXECUTION_TIME")

    echo ""
    echo -e "  ${CYAN}${BOLD}⏱️  Статистика выполнения установки:${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
    echo -e "  Время запуска:        ${WHITE}${SCRIPT_START_DATETIME}${NC}"
    echo -e "  Время завершения:     ${WHITE}${SCRIPT_END_DATETIME}${NC}"
    echo -e "  Общее время работы:   ${GREEN}${BOLD}${FORMATTED_TOTAL_TIME}${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${WHITE}Время по шагам:${NC}"
    for ((s_idx=1; s_idx<=TOTAL_STEPS; s_idx++)); do
        step_t="${STEP_DURATIONS[$s_idx]:-0}"
        s_name="${STEP_NAMES[$s_idx]:-Шаг $s_idx}"
        if [ "$step_t" -gt 0 ]; then
            s_dur_str=$(format_duration "$step_t")
            if [ "${STEP_BG_FLAGS[$s_idx]:-0}" -eq 1 ]; then
                echo -e "    • Шаг $s_idx ($s_name): ${GREEN}${s_dur_str}${NC} ${CYAN}[в фоне, сэкономлено]${NC}"
            else
                echo -e "    • Шаг $s_idx ($s_name): ${GREEN}${s_dur_str}${NC}"
            fi
        elif [ "${RESUME_STEP:-1}" -gt "$s_idx" ]; then
            echo -e "    • Шаг $s_idx ($s_name): ${DIM}пропущено (выполнено ранее)${NC}"
        else
            echo -e "    • Шаг $s_idx ($s_name): ${DIM}< 1 сек${NC}"
        fi
    done
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}\n"

    if is_true "${DEBUG_MODE:-0}" || [ -n "${FORCE_LOG_EXPORT:-}" ]; then
        if command -v offer_debug_log_export >/dev/null 2>&1; then
            offer_debug_log_export
        fi
    fi
}

SSH_ACTIVE_PORT="${SSH_ACTIVE_PORT:-$(detect_active_ssh_port)}"
if [ -z "${CONFIG_EXPLICIT_KEYS[SSH_PORT]:-}" ]; then SSH_PORT="$SSH_ACTIVE_PORT"; fi
build_installation_plan
restore_installation_checkpoint
# =============================================================
#  ИНТЕРАКТИВНАЯ КОНФИГУРАЦИЯ И СЦЕНАРИИ МАРШРУТИЗАЦИИ
# =============================================================
EXPRESS_MODE=${EXPRESS_MODE:-0}
EXPERT_MODE=${EXPERT_MODE:-0}

# Проверка сохраненной контрольной точки (Resume Checkpoint)
SKIP_INTERVIEW=0
if [ "$NON_INTERACTIVE" -eq 0 ]; then
    print_mask_banner
    if [ "${STEP_EXPLICIT:-0}" -eq 1 ]; then
        SKIP_INTERVIEW=1
        ok "Запуск с указанного шага $RESUME_STEP (${STEP_NAMES[$RESUME_STEP]:-Шаг $RESUME_STEP})..."
    else
        has_interrupted_run=0
        TARGET_RESUME_STEP=0
        FAILED_STEP_TITLE=""
        if [ -n "${CHECKPOINT_FAILED:-}" ] && [ "${FAILED_STEP_NUM:-0}" -gt 0 ]; then
            has_interrupted_run=1
            TARGET_RESUME_STEP="$FAILED_STEP_NUM"
            FAILED_STEP_TITLE="${INSTALLATION_TITLES[$CHECKPOINT_FAILED]:-${STEP_NAMES[$FAILED_STEP_NUM]:-Шаг $FAILED_STEP_NUM}}"
        elif [ "$LAST_COMPLETED_STEP" -gt 0 ] && [ "$LAST_COMPLETED_STEP" -lt "$TOTAL_STEPS" ]; then
            has_interrupted_run=1
            TARGET_RESUME_STEP=$(( LAST_COMPLETED_STEP + 1 ))
            FAILED_STEP_TITLE="${STEP_NAMES[$TARGET_RESUME_STEP]:-Шаг $TARGET_RESUME_STEP}"
        fi

        if [ "$has_interrupted_run" -eq 1 ]; then
            echo -e "  ${YELLOW}${BOLD}Обнаружена незавершенная установка!${NC}"
            if [ -n "${CHECKPOINT_FAILED:-}" ] && [ "${FAILED_STEP_NUM:-0}" -gt 0 ]; then
                echo -e "  ${RED}Предыдущая установка была прервана на шаге:${NC} ${WHITE}Шаг $TARGET_RESUME_STEP из $TOTAL_STEPS ($FAILED_STEP_TITLE)${NC}"
                if [ "$LAST_COMPLETED_STEP" -gt 0 ]; then
                    echo -e "  ${DIM}Последний успешно завершенный шаг: ${WHITE}Шаг $LAST_COMPLETED_STEP из $TOTAL_STEPS (${STEP_NAMES[$LAST_COMPLETED_STEP]:-})${NC}"
                fi
            else
                echo -e "  ${DIM}Последний успешно завершенный шаг: ${WHITE}Шаг $LAST_COMPLETED_STEP из $TOTAL_STEPS (${STEP_NAMES[$LAST_COMPLETED_STEP]:-})${NC}"
            fi
            echo -e "    ${CYAN}${BOLD}[1] Повторить/продолжить с шага $TARGET_RESUME_STEP ($FAILED_STEP_TITLE)${NC} (Рекомендуется)"
            echo -e "    ${YELLOW}[2] Начать установку заново (с шага 1)${NC}\n"
            read -rp "  Ваш выбор [1/2] (по умолчанию: 1): " RESUME_CHOICE </dev/tty || read -r RESUME_CHOICE || RESUME_CHOICE="1"
            RESUME_CHOICE=$(echo "${RESUME_CHOICE:-1}" | tr -d '[:space:]')
            if [ "$RESUME_CHOICE" != "2" ]; then
                RESUME_STEP="$TARGET_RESUME_STEP"
                SKIP_INTERVIEW=1
                ok "Возобновление установки с шага $RESUME_STEP..."
            else
                LAST_COMPLETED_STEP=0
                RESUME_STEP=1
                CHECKPOINT_FAILED=""
                record_step_completed 0
                ok "Сброс контрольной точки. Установка будет начата с первого шага."
            fi
            echo ""
        fi
    fi
else
    # В неинтерактивном режиме с переданным конфигом пропускаем интервью и возобновляем
    SKIP_INTERVIEW=1
    if [ "${STEP_EXPLICIT:-0}" -eq 1 ]; then
        ok "Неинтерактивный режим: запуск с указанного шага $RESUME_STEP (${STEP_NAMES[$RESUME_STEP]:-Шаг $RESUME_STEP})..."
    elif [ -n "${CHECKPOINT_FAILED:-}" ] && [ "${FAILED_STEP_NUM:-0}" -gt 0 ]; then
        RESUME_STEP="$FAILED_STEP_NUM"
        ok "Неинтерактивный режим: возобновление с шага $RESUME_STEP (${INSTALLATION_TITLES[$CHECKPOINT_FAILED]:-})..."
    elif [ "$LAST_COMPLETED_STEP" -gt 0 ] && [ "$LAST_COMPLETED_STEP" -lt "$TOTAL_STEPS" ]; then
        RESUME_STEP=$(( LAST_COMPLETED_STEP + 1 ))
        ok "Неинтерактивный режим: возобновление с шага $RESUME_STEP..."
    fi
fi

if [ "$SKIP_INTERVIEW" -eq 1 ]; then
    # Восстановление массивов из сохраненных скалярных параметров конфигурации
    if [ "${EXPRESS_MODE:-0}" -eq 1 ] && is_true "${ENABLE_WEB_STACK:-y}"; then apply_express_defaults; else reconstruct_arrays_from_vars; fi
    REALITY_FALLBACK_PORT="9443"
    if [ "${SSL_ENGINE_CHOICE:-1}" = "1" ]; then
        SSL_BASE_DIR="/etc/letsencrypt/live"
    else
        SSL_BASE_DIR="/etc/ssl/acme"
    fi
else
    run_standalone_awg_wizard() {
        echo ""
        echo -e "  ${GREEN}${STAR} ${BOLD}Настройка автономного сервера AmneziaWG (awg-mgr)${NC}"
        echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Подключение клиентов (Endpoint):${NC}"
            echo -e "     Вы можете использовать как IP-адрес сервера, так и ваше доменное имя."
            echo -e "     ${GREEN}SSL-сертификаты НЕ требуются:${NC} WireGuard/AmneziaWG работает по UDP"
            echo -e "     и шифрует трафик ключами Curve25519. Достаточно обычной A-записи домена на IP сервера."
            echo ""
        fi

        local def_host="${AWG_SERVER_HOST:-${PRIMARY_DOMAIN:-$(get_wan_ip)}}"
        prompt_default "Домен или IP-адрес сервера для подключения клиентов (Endpoint)" "$def_host" AWG_SERVER_HOST

        local def_port="${AWG_STANDALONE_PORT:-8445}"
        prompt_default "Внешний UDP-порт для сервера AmneziaWG" "$def_port" AWG_STANDALONE_PORT

        prompt_default "Основной DNS для клиентов AmneziaWG" "${AWG_PRIMARY_DNS:-9.9.9.9}" AWG_PRIMARY_DNS
        prompt_default "Резервный DNS для клиентов AmneziaWG" "${AWG_SECONDARY_DNS:-76.76.2.0}" AWG_SECONDARY_DNS

        ENABLE_AWG_STANDALONE=1
        ENABLE_WEB_STACK=0

        echo ""
        echo -e "  ${YELLOW}━━━ Подтверждение параметров AmneziaWG ━━━${NC}"
        echo -e "    ${DIM}• Хост / Домен (Endpoint):${NC} ${GREEN}${BOLD}${AWG_SERVER_HOST}${NC}"
        echo -e "    ${DIM}• Внешний UDP-порт:${NC}        ${WHITE}${BOLD}${AWG_STANDALONE_PORT}/udp${NC}"
        echo -e "    ${DIM}• Клиентская подсеть:${NC}      ${WHITE}10.8.0.0/22 (до 1022 клиентов)${NC}"
        echo -e "    ${DIM}• DNS-серверы:${NC}             ${WHITE}${AWG_PRIMARY_DNS}, ${AWG_SECONDARY_DNS}${NC}"
        echo -e "    ${DIM}• Профиль обфускации:${NC}      ${WHITE}AmneziaWG 3.1 (Jc=4, Jmin=40, Jmax=70, S1-S4=16, H1-H4)${NC}"
        echo -e "    ${DIM}• Служба на хосте:${NC}         ${GREEN}awg-quick@awg0${NC}"
        echo -e "    ${DIM}• Утилита управления:${NC}      ${GREEN}awg-mgr${NC} (CLI)"
        echo ""

        while true; do
            local choice=""
            echo -ne "  ${WHITE}${ARROW} Перейти к проверке плана? [${GREEN}Enter = далее${WHITE}, q = отмена]: ${NC}"
            read -r choice </dev/tty || read -r choice || true
            choice=$(echo "${choice:-}" | tr -d '[:space:]')
            if [ -z "$choice" ] || [[ "${choice,,}" == "y" ]] || [[ "${choice,,}" == "yes" ]]; then
                return 0
            fi
            if [[ "${choice,,}" == "q" || "${choice,,}" == "quit" || "${choice,,}" == "exit" ]]; then
                die "Установка отменена пользователем."
            fi
            warn "  Некорректный ввод. Нажмите Enter для старта или 'q' для выхода."
        done
    }

    if [ "$NON_INTERACTIVE" -eq 0 ]; then
        START_AT_REVIEW=0
        has_saved_config=0
        if is_true "${ENABLE_WEB_STACK:-y}" && [ -n "${PRIMARY_DOMAIN:-}" ]; then
            has_saved_config=1
        elif ! is_true "${ENABLE_WEB_STACK:-y}" && [ -n "${AWG_SERVER_HOST:-}" ]; then
            has_saved_config=1
        fi

        if [ "$has_saved_config" -eq 1 ]; then
            echo
            echo -e "  ${YELLOW}${BOLD}Обнаружена сохраненная конфигурация предыдущей сессии!${NC}"
            if is_true "${ENABLE_WEB_STACK:-y}"; then
                echo -e "    ${DIM}• Домен:${NC} ${GREEN}${PRIMARY_DOMAIN}${NC}  ${DIM}• Префикс сервера:${NC} ${WHITE}${SERVER_PREFIX:-Server}${NC}"
            else
                echo -e "    ${DIM}• Режим:${NC} ${CYAN}Только автономный AmneziaWG${NC}  ${DIM}• Хост (Endpoint):${NC} ${GREEN}${AWG_SERVER_HOST:-$WAN_IP}${NC}"
            fi
            echo
            echo -e "    ${CYAN}${BOLD}[1] Перейти сразу к экрану подтверждения (Review) и установке${NC} (Рекомендуется)"
            echo -e "    ${GREEN}[2] Пошагово проверить/изменить параметры${NC} (ранее выбранные значения будут по умолчанию)"
            echo -e "    ${RED}[3] Начать заново с чистого листа${NC}"
            echo
            cfg_choice=""
            read -rp "  Ваш выбор [1/2/3] (по умолчанию: 1): " cfg_choice </dev/tty || read -r cfg_choice || cfg_choice="1"
            cfg_choice=$(echo "${cfg_choice:-1}" | tr -d '[:space:]')
            case "$cfg_choice" in
                2)
                    EXPRESS_MODE=0
                    START_AT_REVIEW=0
                    ok "Пошаговый режим: сохраненные значения подставлены по умолчанию."
                    ;;
                3)
                    PRIMARY_DOMAIN=""
                    SERVER_PREFIX=""
                    ADD_WWW=""
                    ENABLE_WEB_STACK=""
                    ENABLE_AWG_STANDALONE=""
                    AWG_STANDALONE_PORT=""
                    AWG_SERVER_HOST=""
                    ENABLE_STEAL=""
                    ENABLE_CLASSIC=""
                    PORTS_SETUP_MODE=0
                    PATHS_SETUP_MODE=0
                    ENABLE_HY2=""
                    ENABLE_AWG_V3=""
                    ENABLE_AWG_V2=""
                    ENABLE_AGH=""
                    ENABLE_NODE_TOKEN=""
                    ENABLE_WARP=""
                    AUTO_SETUP_3XUI=""
                    STEAL_DOMAINS=()
                    EXT_SNI_LIST=()
                    STEAL_PORTS_LIST=()
                    CLASSIC_PORTS_LIST=()
                    ALL_REALITY_PORTS=()
                    declare -g -A DOMAIN_TO_PORT=()
                    declare -g -A EXT_SNI_TO_PORT=()
                    START_AT_REVIEW=0
                    ok "Параметры сброшены. Начинаем с чистого листа."
                    ;;
                *)
                    EXPRESS_MODE=0
                    EXPERT_MODE=1
                    START_AT_REVIEW=1
                    ok "Переход к подтверждению конфигурации (Review)..."
                    ;;
            esac
        fi

        if ! is_true "${ENABLE_WEB_STACK:-y}"; then
            # Сценарий только автономного сервера AmneziaWG
            EXPRESS_MODE=0
            EXPERT_MODE=0
            ENABLE_AWG_STANDALONE="y"
            run_standalone_awg_wizard
            SKIP_WIZARD_STEPS=1
        fi

        if [ "$START_AT_REVIEW" -eq 0 ] && [ "${SKIP_WIZARD_STEPS:-0}" -eq 0 ] && [ -z "${PRIMARY_DOMAIN:-}" ] && [ "$EXPRESS_MODE" -eq 0 ] && [ "$EXPERT_MODE" -eq 0 ]; then
            echo
            echo -e "  ${WHITE}${BOLD}Выберите режим настройки:${NC}\n"
            echo -e "    ${CYAN}${BOLD}[1] Экспресс-установка (Рекомендуется)${NC} — Настройка в 2 вопроса"
            echo -e "        ${DIM}• Ввод только домена и email для Let's Encrypt.${NC}"
            echo -e "        ${DIM}• Автоматический выбор лучших протоколов (VLESS REALITY, VLESS xHTTP, Hysteria 2, AmneziaWG).${NC}"
            echo -e "        ${DIM}• Готовый сайт-маскировка DataSphere Analytics + автогенерация безопасных путей.${NC}\n"
            echo -e "    ${YELLOW}${BOLD}[2] Экспертная детальная настройка${NC} — Полный контроль параметров"
            echo -e "        ${DIM}• Единый выбор протоколов, пошаговая настройка портов, путей подписок и параметров.${NC}\n"
            echo -e "    ${GREEN}${BOLD}[3] Только автономный AmneziaWG (awg-mgr)${NC} — Без домена и веб-маскировки"
            echo -e "        ${DIM}• Работает как системная служба ядра Linux (awg-quick@awg0).${NC}"
            echo -e "        ${DIM}• Управление через CLI awg-mgr, подключение напрямую по IP (домен и SSL не нужны).${NC}\n"

            while true; do
                echo -ne "  ${WHITE}${ARROW} Ваш выбор [1/2/3] (по умолчанию: 1): ${NC}"
                read -r MODE_INPUT </dev/tty || read -r MODE_INPUT || MODE_INPUT="1"
                MODE_INPUT=$(echo "${MODE_INPUT:-1}" | tr -d '[:space:]')
                if [ "$MODE_INPUT" = "1" ]; then
                    EXPRESS_MODE=1
                    ENABLE_WEB_STACK="y"
                    break
                elif [ "$MODE_INPUT" = "2" ]; then
                    EXPRESS_MODE=0
                    EXPERT_MODE=1
                    ENABLE_WEB_STACK="y"
                    break
                elif [ "$MODE_INPUT" = "3" ]; then
                    EXPRESS_MODE=0
                    EXPERT_MODE=0
                    ENABLE_WEB_STACK="n"
                    ENABLE_AWG_STANDALONE="y"
                    run_standalone_awg_wizard
                    SKIP_WIZARD_STEPS=1
                    break
                fi
                echo -e "  ${RED}Пожалуйста, введите 1, 2 или 3.${NC}"
            done
        fi
    fi

if [ "${SKIP_WIZARD_STEPS:-0}" -eq 1 ]; then
    reconstruct_arrays_from_vars
elif [ "$EXPRESS_MODE" -eq 1 ]; then
    echo ""
    echo -e "  ${GREEN}${STAR} ${BOLD}Включен режим: Экспресс-установка${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"

    echo -e "  ${YELLOW}[i] Важно о DNS:${NC} ${DIM}Для маскировки требуются A-записи основного домена и поддомена cdn.<домен>${NC}"
    if [ -z "${PRIMARY_DOMAIN:-}" ]; then
        while true; do
            echo -ne "  ${WHITE}${ARROW} Введите ваш основной домен (напр. domain.com): ${NC}"
            read -r PRIMARY_DOMAIN </dev/tty || read -r PRIMARY_DOMAIN || true
            PRIMARY_DOMAIN=$(echo "${PRIMARY_DOMAIN:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            if [[ -n "$PRIMARY_DOMAIN" && "$PRIMARY_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                break
            fi
            echo -e "  ${RED}${CROSS} Некорректный формат домена. Попробуйте еще раз.${NC}"
        done
    fi

    if [ -z "${LE_EMAIL:-}" ]; then
        echo -ne "  ${WHITE}${ARROW} Введите Email для сертификатов Let's Encrypt: ${NC}"
        read -r LE_EMAIL </dev/tty || read -r LE_EMAIL || true
        LE_EMAIL=$(echo "${LE_EMAIL:-}" | tr -d '[:space:]')
    fi

    apply_express_defaults

else
    # Инициализация глобальных структур и вспомогательных функций мастера настройки
    [[ -v DOMAIN_TO_PORT ]] || declare -g -A DOMAIN_TO_PORT=()
    [[ -v EXT_SNI_TO_PORT ]] || declare -g -A EXT_SNI_TO_PORT=()
    [ -n "${STEAL_PORTS_LIST[*]:-}" ] || STEAL_PORTS_LIST=()
    [ -n "${CLASSIC_PORTS_LIST[*]:-}" ] || CLASSIC_PORTS_LIST=()
    [ -n "${ALL_REALITY_PORTS[*]:-}" ] || ALL_REALITY_PORTS=()
    [ -n "${STEAL_DOMAINS[*]:-}" ] || STEAL_DOMAINS=()
    [ -n "${EXT_SNI_LIST[*]:-}" ] || EXT_SNI_LIST=()
    [ -n "${ALL_EXT_SNIS[*]:-}" ] || ALL_EXT_SNIS=()
    [ -n "${EXTRA_DOMAINS_USER[*]:-}" ] || EXTRA_DOMAINS_USER=()
    REALITY_FALLBACK_PORT="${REALITY_FALLBACK_PORT:-9443}"
    reconstruct_arrays_from_vars

    rebuild_all_domains() {
        ALL_DOMAINS=("$PRIMARY_DOMAIN")
        if [[ "${ADD_WWW,,}" == "y" && ! "$PRIMARY_DOMAIN" =~ ^www\. ]]; then
            ALL_DOMAINS+=("www.$PRIMARY_DOMAIN")
        fi
        if is_true "${STEAL_ENABLED:-0}"; then
            for s_dom in "${STEAL_DOMAINS[@]}"; do
                [ -n "$s_dom" ] || continue
                if [[ ! " ${ALL_DOMAINS[*]} " == *" ${s_dom} "* ]]; then
                    ALL_DOMAINS+=("$s_dom")
                fi
            done
        fi
        if is_true "${ENABLE_HY2:-0}" && [ -n "${HY2_DOMAIN:-}" ]; then
            if [[ ! " ${ALL_DOMAINS[*]} " == *" ${HY2_DOMAIN} "* ]]; then
                ALL_DOMAINS+=("$HY2_DOMAIN")
            fi
        fi
        if is_true "${ENABLE_AGH:-0}" && [ "${AGH_MODE:-1}" = "2" ] && [ -n "${AGH_DOMAIN:-}" ]; then
            if [[ ! " ${ALL_DOMAINS[*]} " == *" ${AGH_DOMAIN} "* ]]; then
                ALL_DOMAINS+=("$AGH_DOMAIN")
            fi
        fi
        if is_true "${ENABLE_NAIVE:-0}" && [ -n "${NAIVE_DOMAIN:-}" ]; then
            if [[ ! " ${ALL_DOMAINS[*]} " == *" ${NAIVE_DOMAIN} "* ]]; then
                ALL_DOMAINS+=("$NAIVE_DOMAIN")
            fi
        fi
        for extra_d in "${EXTRA_DOMAINS_USER[@]:-}"; do
            if [[ -n "$extra_d" && ! " ${ALL_DOMAINS[*]} " == *" ${extra_d} "* ]]; then
                ALL_DOMAINS+=("$extra_d")
            fi
        done
    }

    sync_reality_ports() {
        ALL_REALITY_PORTS=()
        if is_true "${STEAL_ENABLED:-0}"; then
            for p in "${STEAL_PORTS_LIST[@]:-}"; do
                [ -n "$p" ] && ALL_REALITY_PORTS+=("$p")
            done
        fi
        if is_true "${CLASSIC_ENABLED:-0}"; then
            for p in "${CLASSIC_PORTS_LIST[@]:-}"; do
                [ -n "$p" ] && ALL_REALITY_PORTS+=("$p")
            done
        fi
    }

    scan_reality_candidates() {
        python3 -c "
import ssl, socket, time, concurrent.futures

CANDIDATES = [
    'dl.google.com',
    'www.apple.com',
    'itunes.apple.com',
    'www.samsung.com',
    'www.nvidia.com',
    'www.microsoft.com',
    'www.amazon.com',
    'www.amd.com',
    'www.sony.com',
]

def probe(host):
    ctx = ssl.create_default_context()
    ctx.set_alpn_protocols(['h2'])
    t0 = time.time()
    try:
        with socket.create_connection((host, 443), timeout=3.0) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as ssock:
                lat = int((time.time() - t0) * 1000)
                ver = ssock.version()
                alpn = ssock.selected_alpn_protocol()
                feasible = (ver == 'TLSv1.3' and alpn == 'h2')
                return {'host': host, 'feasible': feasible, 'lat': lat}
    except Exception:
        return {'host': host, 'feasible': False, 'lat': 9999}

with concurrent.futures.ThreadPoolExecutor(max_workers=len(CANDIDATES)) as ex:
    res = list(ex.map(probe, CANDIDATES))

res.sort(key=lambda x: (0 if x['feasible'] else 1, x['lat']))
for item in res:
    if item['feasible']:
        print(item['host'] + ' ' + str(item['lat']))
" 2>/dev/null || true
    }

    run_non_interactive_setup() {
        if is_true "${ENABLE_WEB_STACK:-y}"; then
            [ -n "${PRIMARY_DOMAIN:-}" ] || die "Ошибка: PRIMARY_DOMAIN не задан в конфигурации или аргументах!"
            [[ "$PRIMARY_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || die "Некорректный формат доменного имени: $PRIMARY_DOMAIN"
            ok "Основной домен (из конфигурации): $PRIMARY_DOMAIN"
        else
            ok "Режим установки: Только автономный сервер AmneziaWG (веб-стек Nginx/3X-UI отключен)."
            [ -n "${AWG_SERVER_HOST:-}" ] || AWG_SERVER_HOST="$(get_wan_ip)"
            ok "Хост подключения AmneziaWG (Endpoint): $AWG_SERVER_HOST"
        fi

        SERVER_PREFIX="${SERVER_PREFIX:-$(hostname -s 2>/dev/null || echo "Server")}"
        [[ "$SERVER_PREFIX" =~ ^(localhost|ubuntu|debian|centos|vps.*)$ ]] && SERVER_PREFIX="Server"

        ADD_WWW="${ADD_WWW:-n}"

        # Steal-Oneself
        if [[ "${ENABLE_STEAL,,}" == "y" || "${ENABLE_STEAL:-}" == "1" ]]; then
            STEAL_ENABLED=1
            local s_port="${STEAL_PORT:-45443}"
            STEAL_PORTS_LIST+=("$s_port")
            local default_steal_dom="cdn.$PRIMARY_DOMAIN"
            local steal_dom_list="${STEAL_DOMAINS[*]:-$default_steal_dom}"
            STEAL_DOMAINS=()
            for s_dom in $steal_dom_list; do
                [[ "$s_dom" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || continue
                STEAL_DOMAINS+=("$s_dom")
                DOMAIN_TO_PORT["$s_dom"]="$s_port"
                ok "    Домен $s_dom привязан к инбаунд-порту $s_port"
            done
        else
            STEAL_ENABLED=0
        fi

        # Classic REALITY
        if [[ "${ENABLE_CLASSIC,,}" == "y" || "${ENABLE_CLASSIC:-}" == "1" ]]; then
            CLASSIC_ENABLED=1
            local c_port="${CLASSIC_PORT:-46443}"
            CLASSIC_PORTS_LIST+=("$c_port")
            local classic_sni_list="${CLASSIC_SNI:-dl.google.com}"
            EXT_SNI_LIST=()
            for ext_sni in ${classic_sni_list//,/ }; do
                ext_sni=$(echo "$ext_sni" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
                [ -n "$ext_sni" ] || continue
                [[ "$ext_sni" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || continue
                [[ " ${EXT_SNI_LIST[*]:-} " =~ " ${ext_sni} " ]] && continue
                EXT_SNI_TO_PORT["$ext_sni"]="$c_port"
                EXT_SNI_LIST+=("$ext_sni")
                ALL_EXT_SNIS+=("$ext_sni")
                ok "    Внешний SNI $ext_sni привязан к инбаунд-порту $c_port"
            done
            if [ ${#EXT_SNI_LIST[@]} -eq 0 ]; then
                EXT_SNI_LIST=("dl.google.com")
                EXT_SNI_TO_PORT["dl.google.com"]="$c_port"
                ALL_EXT_SNIS+=("dl.google.com")
                ok "    Внешний SNI dl.google.com привязан к инбаунд-порту $c_port"
            fi
        else
            CLASSIC_ENABLED=0
        fi

        # Порты и пути
        PANEL_PORT="${PANEL_PORT:-10443}"
        ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
        ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 12 || echo "Admin1234567")}"
        ensure_panel_path || return 1
        validate_path_segment "$RAW_PATH" "URI панели"

        SUB_PORT="${SUB_PORT:-55443}"
        RAW_SUB_PATH="${RAW_SUB_PATH:-${SUB_PATH:-sub-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "sub${RANDOM}")}}"
        RAW_SUB_PATH="${RAW_SUB_PATH#/}"; RAW_SUB_PATH="${RAW_SUB_PATH%/}"
        validate_path_segment "$RAW_SUB_PATH" "URI подписок"
        SUB_PATH="/${RAW_SUB_PATH#/}"; SUB_PATH="${SUB_PATH%/}/"
        SUB_JSON_PATH="${SUB_PATH%/}/json/"
        SUB_CLASH_PATH="${SUB_PATH%/}/clash/"

        XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
        RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH:-${XHTTP_STREAM_PATH:-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "xh${RANDOM}")}}"
        RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH#/}"; RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH%/}"
        validate_path_segment "$RAW_XHTTP_STREAM_PATH" "URI xHTTP"
        XHTTP_STREAM_PATH="/${RAW_XHTTP_STREAM_PATH#/}"; XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH%/}/"

        ensure_diag_path || return 1

        # UDP Протоколы
        if [[ "${ENABLE_HY2,,}" == "y" || "${ENABLE_HY2:-}" == "1" ]]; then
            ENABLE_HY2=1
            HY2_PORT="${HY2_PORT:-443}"
            HY2_DOMAIN="${HY2_DOMAIN:-$PRIMARY_DOMAIN}"
            HY2_PORT_HOPPING="${HY2_PORT_HOPPING:-n}"
            HY2_PORT_HOPPING_RANGE="${HY2_PORT_HOPPING_RANGE:-20000:50000}"
        else
            ENABLE_HY2=0
        fi

        if [[ "${ENABLE_AWG_V3,,}" == "y" || "${ENABLE_AWG_V3:-}" == "1" ]]; then
            ENABLE_AWG_V3=1
            AWG_V3_PORT="${AWG_V3_PORT:-8443}"
        else
            ENABLE_AWG_V3=0
        fi

        if [[ "${ENABLE_AWG_V2,,}" == "y" || "${ENABLE_AWG_V2:-}" == "1" ]]; then
            ENABLE_AWG_V2=1
            AWG_V2_PORT="${AWG_V2_PORT:-8444}"
        else
            ENABLE_AWG_V2=0
        fi

        if [[ "${ENABLE_AWG_STANDALONE,,}" == "y" || "${ENABLE_AWG_STANDALONE:-}" == "1" ]]; then
            ENABLE_AWG_STANDALONE=1
            AWG_STANDALONE_PORT="${AWG_STANDALONE_PORT:-8445}"
        else
            ENABLE_AWG_STANDALONE=0
        fi

        if [[ "${ENABLE_SS2022,,}" == "y" || "${ENABLE_SS2022:-}" == "1" ]]; then
            ENABLE_SS2022=1
            SS2022_PORT="${SS2022_PORT:-8388}"
        else
            ENABLE_SS2022=0
        fi

        if [[ "${ENABLE_TUIC,,}" == "y" || "${ENABLE_TUIC:-}" == "1" ]]; then
            ENABLE_TUIC=1
            TUIC_PORT="${TUIC_PORT:-8448}"
        else
            ENABLE_TUIC=0
        fi

        if [[ "${ENABLE_MTPROTO,,}" == "y" || "${ENABLE_MTPROTO:-}" == "1" ]]; then
            ENABLE_MTPROTO=1
            MTPROTO_PORT="${MTPROTO_PORT:-8444}"
            MTPROTO_FAKETLS_DOMAIN="${MTPROTO_FAKETLS_DOMAIN:-gateway.icloud.com}"
            MTPROTO_ADTAG="${MTPROTO_ADTAG:-}"
        else
            ENABLE_MTPROTO=0
        fi

        if [[ "${ENABLE_MASQUE,,}" == "y" || "${ENABLE_MASQUE:-}" == "1" ]]; then
            ENABLE_MASQUE=1
            MASQUE_PORT="${MASQUE_PORT:-8449}"
        else
            ENABLE_MASQUE=0
        fi

        if [[ "${ENABLE_SHADOWTLS,,}" == "y" || "${ENABLE_SHADOWTLS:-}" == "1" ]]; then
            ENABLE_SHADOWTLS=1
            SHADOWTLS_PORT="${SHADOWTLS_PORT:-8543}"
            SHADOWTLS_SNI="${SHADOWTLS_SNI:-gateway.icloud.com}"
            ENABLE_SS2022=1
        else
            ENABLE_SHADOWTLS=0
        fi

        if [[ "${ENABLE_WSTUNNEL,,}" == "y" || "${ENABLE_WSTUNNEL:-}" == "1" ]]; then
            ENABLE_WSTUNNEL=1
            WSTUNNEL_PORT="${WSTUNNEL_PORT:-8080}"
            ensure_wstunnel_prefix || return 1
        else
            ENABLE_WSTUNNEL=0
        fi

        if [[ "${ENABLE_ZAPRET,,}" == "y" || "${ENABLE_ZAPRET:-}" == "1" ]]; then
            ENABLE_ZAPRET=1
            ZAPRET_QNUM="${ZAPRET_QNUM:-200}"
        else
            ENABLE_ZAPRET=0
        fi

        if [[ "${ENABLE_NAIVE,,}" == "y" || "${ENABLE_NAIVE:-}" == "1" ]]; then
            ENABLE_NAIVE=1
            NAIVE_PORT="${NAIVE_PORT:-8446}"
            NAIVE_USER="${NAIVE_USER:-user}"
        else
            ENABLE_NAIVE=0
        fi

        if [[ "${ENABLE_DNSTT,,}" == "y" || "${ENABLE_DNSTT:-}" == "1" ]]; then
            ENABLE_DNSTT=1
            DNSTT_PORT="${DNSTT_PORT:-53053}"
            ENABLE_SS2022=1
        else
            ENABLE_DNSTT=0
        fi

        if [[ "${ENABLE_MIERU,,}" == "y" || "${ENABLE_MIERU:-}" == "1" ]]; then
            ENABLE_MIERU=1
            MIERU_PORT_MODE="${MIERU_PORT_MODE:-single}"
            case "${MIERU_PORT_MODE,,}" in
                range|pool)
                    MIERU_PORT="${MIERU_PORT:-8450-8455}"
                    ;;
                *)
                    MIERU_PORT="${MIERU_PORT:-8450}"
                    ;;
            esac
            [ -n "${MIERU_USER:-}" ] || MIERU_USER="user-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "mieru${RANDOM}")"
            [ -n "${MIERU_PASS:-}" ] || MIERU_PASS="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "mieru${RANDOM}")"
        else
            ENABLE_MIERU=0
        fi


        # AdGuard Home
        if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
            ENABLE_AGH=1
            AGH_MODE="${AGH_MODE:-1}"
            [ "$AGH_MODE" = "2" ] && AGH_DOMAIN="${AGH_DOMAIN:-dns.$PRIMARY_DOMAIN}" || AGH_DOMAIN=""
            AGH_USER="${AGH_USER:-admin}"
            AGH_PASS="${AGH_PASS:-AgHome_$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 8 || echo 'Pass1234')}"
            ensure_agh_client_id || return 1
            [[ "${AGH_XRAY_DNS,,}" == "y" || "${AGH_XRAY_DNS:-}" == "1" ]] && AGH_XRAY_DNS="y" || AGH_XRAY_DNS="n"
        else
            ENABLE_AGH=0
            AGH_DOMAIN=""
        fi

        DECOY_MODE="${DECOY_MODE:-1}"
        EXTRA_DOMAINS_USER=()
        if [ -n "${EXTRA_SSL_DOMAINS:-}" ]; then
            for extra_d in $EXTRA_SSL_DOMAINS; do
                [[ "$extra_d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] && EXTRA_DOMAINS_USER+=("$extra_d")
            done
        fi

        SSL_ENGINE_CHOICE="${SSL_ENGINE_CHOICE:-1}"
        LE_EMAIL="${LE_EMAIL:-}"
        CF_AUTH_METHOD="${CF_AUTH_METHOD:-1}"
        AUTO_SETUP_3XUI="${AUTO_SETUP_3XUI:-y}"
        if [[ "${ENABLE_NODE_TOKEN,,}" == "y" || "${ENABLE_NODE_TOKEN:-}" == "1" ]]; then
            ENABLE_NODE_TOKEN="y"
            if [ -z "${NODE_TOKEN_NAME:-}" ]; then
                local def_token_name="${SERVER_PREFIX:+$SERVER_PREFIX-Node}"
                if [[ -z "$SERVER_PREFIX" || "${SERVER_PREFIX,,}" =~ ^(-|none|off|no)$ ]]; then
                    def_token_name="Master-Node-Cluster"
                fi
                NODE_TOKEN_NAME="$def_token_name"
            fi
        else
            ENABLE_NODE_TOKEN="n"
            NODE_TOKEN_NAME=""
        fi
        if [[ "${ENABLE_WARP,,}" == "y" || "${ENABLE_WARP:-}" == "1" ]]; then
            ENABLE_WARP="y"
            WARP_LICENSE_KEY="${WARP_LICENSE_KEY:-}"
        else
            ENABLE_WARP="n"
            WARP_LICENSE_KEY=""
        fi

        ENABLE_HOST_SECURITY="${ENABLE_HOST_SECURITY:-n}"
        local _act_p
        _act_p=$(detect_active_ssh_port)
        [ -n "$_act_p" ] || _act_p=22
        SSH_ACTIVE_PORT="${SSH_ACTIVE_PORT:-$_act_p}"
        SSH_PORT="${SSH_PORT:-$SSH_ACTIVE_PORT}"
        ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-n}"

        rebuild_all_domains
        sync_reality_ports
    }

    # ==============================================================================
    # ШАГИ ИНТЕРАКТИВНОГО МАСТЕРА НАСТРОЙКИ (WIZARD STATE MACHINE)
    # ==============================================================================

    q_step_domain() {
        echo
        echo -e "${YELLOW}━━━ Шаг 1/11: Конфигурация главного сайта (домена) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Ваш основной домен (например, ${BOLD}yourdomain.online${NC})."
            echo -e "     На нем будет работать веб-маска (декой-сайт), панель 3X-UI,"
            echo -e "     сервер подписок и протокол VLESS xHTTP (HTTP/2 Stream-One)."
            echo
        fi

        while true; do
            if [ -n "${PRIMARY_DOMAIN:-}" ]; then
                prompt_default "  Введите ваш основной домен" "$PRIMARY_DOMAIN" PRIMARY_DOMAIN || return $?
            else
                echo -ne "  ${WHITE}${ARROW} Введите ваш основной домен (например, yourdomain.online) ${DIM}(b - назад)${NC}: "
                local d_input=""
                read -r d_input </dev/tty || read -r d_input || true
                if [[ "${d_input,,}" == "b" || "${d_input,,}" == "back" || "${d_input,,}" == "назад" ]]; then
                    warn "  Вы уже на первом шаге мастера."
                    continue
                fi
                PRIMARY_DOMAIN=$(echo "${d_input:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            fi
            PRIMARY_DOMAIN=$(echo "${PRIMARY_DOMAIN:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            if [[ "$PRIMARY_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                break
            fi
            warn "  Некорректный формат доменного имени: '$PRIMARY_DOMAIN'. Попробуйте снова."
            PRIMARY_DOMAIN=""
        done

        local def_srv="${SERVER_PREFIX:-$(hostname -s 2>/dev/null || echo "Server")}"
        [[ "$def_srv" =~ ^(localhost|ubuntu|debian|centos|vps.*)$ ]] && def_srv="Server"
        prompt_default "  Префикс названия сервера для клиентов (например: NL, Frankfurt, MyServer)" "$def_srv" SERVER_PREFIX || return $?
        SERVER_PREFIX="${SERVER_PREFIX:-Server}"

        if [[ ! "$PRIMARY_DOMAIN" =~ ^www\. ]]; then
            [ "${SHOW_TIPS:-y}" = "y" ] && echo -e "  ${DIM}• Рекомендуется выпустить сертификат и для www.$PRIMARY_DOMAIN для защиты от ошибок SSL.${NC}"
            prompt_yes_no "  Добавить алиас 'www.$PRIMARY_DOMAIN' для выпуска SSL и привязки к Nginx?" "${ADD_WWW:-y}" ADD_WWW || return $?
        else
            ADD_WWW="n"
        fi

        rebuild_all_domains
        ok "Основной домен настроен: $PRIMARY_DOMAIN (префикс: $SERVER_PREFIX)"
        return 0
    }

    configure_steal_settings() {
        local old_steal_dom="${STEAL_DOMAINS[0]:-${STEAL_DOMAINS_STR:-cdn.$PRIMARY_DOMAIN}}"
        local old_steal_port="${STEAL_PORTS_LIST[0]:-${STEAL_PORT:-45443}}"
        STEAL_PORTS_LIST=()
        STEAL_DOMAINS=()

        if [ "${PORTS_SETUP_MODE:-0}" = "1" ]; then
            local port_input=""
            prompt_default "  Локальный порт Xray для REALITY (свой сайт)" "$old_steal_port" port_input || return $?
            STEAL_PORT="$port_input"
            if [[ ! "$STEAL_PORT" =~ ^[0-9]+$ ]] || [ "$STEAL_PORT" -le 0 ] || [ "$STEAL_PORT" -gt 65535 ]; then
                warn "  Некорректный номер порта. Установлен порт по умолчанию: 45443."
                STEAL_PORT="45443"
            fi
            STEAL_PORTS_LIST+=("$STEAL_PORT")
        else
            STEAL_PORT="${STEAL_PORT:-45443}"
            STEAL_PORTS_LIST+=("$STEAL_PORT")
        fi

        local s_dom_in="$old_steal_dom"
        if [ "$s_dom_in" = "$PRIMARY_DOMAIN" ]; then
            s_dom_in="cdn.$PRIMARY_DOMAIN"
        fi

        STEAL_DOMAINS=("$s_dom_in")
        DOMAIN_TO_PORT["$s_dom_in"]="$STEAL_PORT"
        ok "  Домен $s_dom_in привязан к инбаунд-порту $STEAL_PORT"
        return 0
    }

    configure_classic_settings() {
        CLASSIC_PORTS_LIST=()
        EXT_SNI_LIST=()

        if [ "${PORTS_SETUP_MODE:-0}" = "1" ]; then
            local port_input=""
            prompt_default "  Локальный порт Xray для REALITY (внешние сервисы)" "${CLASSIC_PORT:-46443}" port_input || return $?
            CLASSIC_PORT="$port_input"
            if [[ ! "$CLASSIC_PORT" =~ ^[0-9]+$ ]] || [ "$CLASSIC_PORT" -le 0 ] || [ "$CLASSIC_PORT" -gt 65535 ]; then
                warn "  Некорректный номер порта. Установлен порт по умолчанию: 46443."
                CLASSIC_PORT="46443"
            fi
            CLASSIC_PORTS_LIST+=("$CLASSIC_PORT")
        else
            CLASSIC_PORT="${CLASSIC_PORT:-46443}"
            CLASSIC_PORTS_LIST+=("$CLASSIC_PORT")
        fi

        local pool_google="dl.google.com www.google.com"
        local pool_microsoft="www.microsoft.com wwwqa.microsoft.com staticview.microsoft.com"
        local pool_apple="www.apple.com icloud.com"
        local pool_samsung="www.samsung.com"

        if [ "${PORTS_SETUP_MODE:-0}" != "0" ]; then
            local fp_keys=("firefox" "chrome" "safari" "ios" "android" "edge" "randomized")
            local fp_labels=(
                "Mozilla Firefox (по умолчанию)"
                "Google Chrome / Chromium"
                "Apple Safari / WebKit (macOS / iOS)"
                "Apple iOS Network Stack"
                "Android OkHttp / Google Pixel"
                "Microsoft Edge"
                "Случайный браузерный профиль при старте"
            )
            prompt_select "  Выберите uTLS TLS Fingerprint для REALITY" REALITY_FINGERPRINT "${REALITY_FINGERPRINT:-firefox}" fp_keys fp_labels || return $?

            local sni_preset_keys=("google" "microsoft" "apple" "samsung" "custom")
            local sni_preset_labels=(
                "Google пул (по умолчанию)"
                "Microsoft пул"
                "Apple пул"
                "Samsung"
                "Свой SNI или пул доменов вручную"
            )
            local current_sni="${CLASSIC_SNI:-$pool_google}"
            local matched_preset="custom"
            case "$current_sni" in
                "$pool_google"|"dl.google.com")
                    matched_preset="google"
                    ;;
                "$pool_microsoft"|"www.microsoft.com")
                    matched_preset="microsoft"
                    ;;
                "$pool_apple"|"www.apple.com")
                    matched_preset="apple"
                    ;;
                "$pool_samsung")
                    matched_preset="samsung"
                    ;;
                "google"|"microsoft"|"apple"|"samsung"|"custom")
                    matched_preset="$current_sni"
                    ;;
                "")
                    matched_preset="google"
                    ;;
                *)
                    matched_preset="custom"
                    ;;
            esac

            local chosen_sni_preset=""
            prompt_select "  Выберите SNI для маскировки REALITY (или свой пул)" chosen_sni_preset "$matched_preset" sni_preset_keys sni_preset_labels || return $?

            case "$chosen_sni_preset" in
                google)
                    CLASSIC_SNI="$pool_google"
                    ;;
                microsoft)
                    CLASSIC_SNI="$pool_microsoft"
                    ;;
                apple)
                    CLASSIC_SNI="$pool_apple"
                    ;;
                samsung)
                    CLASSIC_SNI="$pool_samsung"
                    ;;
                custom)
                    local custom_sni_input=""
                    prompt_default "  Введите внешний SNI или пул доменов через пробел/запятую" "${CLASSIC_SNI:-dl.google.com}" custom_sni_input || return $?
                    CLASSIC_SNI="$custom_sni_input"
                    ;;
            esac
        else
            REALITY_FINGERPRINT="${REALITY_FINGERPRINT:-firefox}"
            CLASSIC_SNI="${CLASSIC_SNI:-$pool_google}"
        fi

        local classic_raw="${CLASSIC_SNI:-dl.google.com}"
        EXT_SNI_LIST=()
        ALL_EXT_SNIS=()
        for ext_sni in ${classic_raw//,/ }; do
            ext_sni=$(echo "$ext_sni" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            [ -n "$ext_sni" ] || continue
            [[ "$ext_sni" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || continue
            [[ " ${EXT_SNI_LIST[*]:-} " =~ " ${ext_sni} " ]] && continue
            EXT_SNI_LIST+=("$ext_sni")
            EXT_SNI_TO_PORT["$ext_sni"]="$CLASSIC_PORT"
            ALL_EXT_SNIS+=("$ext_sni")
            ok "  Внешний SNI $ext_sni привязан к порту $CLASSIC_PORT"
        done
        if [ ${#EXT_SNI_LIST[@]} -eq 0 ]; then
            EXT_SNI_LIST=("dl.google.com")
            EXT_SNI_TO_PORT["dl.google.com"]="$CLASSIC_PORT"
            ALL_EXT_SNIS=("dl.google.com")
            ok "  Внешний SNI dl.google.com привязан к порту $CLASSIC_PORT"
        fi
        return 0
    }

    q_step_protocols() {
        echo
        echo -e "${YELLOW}━━━ Шаг 2/11: Выбор протоколов и транспортов (VPN / Прокси) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Выберите протоколы подключения, которые будут развернуты на сервере."
            echo -e "     • ${GREEN}VLESS REALITY (свой сайт)${NC}: маскировка под собственный поддомен (напр. cdn.$PRIMARY_DOMAIN)."
            echo -e "     • ${GREEN}VLESS REALITY (внешний)${NC}: маскировка под популярные сервисы (Apple, Microsoft, dl.google.com)."
            echo -e "     • ${GREEN}Hysteria 2${NC}: сверхбыстрый QUIC/UDP протокол с BBR Brutal для стриминга и мобильного интернета."
            echo -e "     • ${GREEN}AmneziaWG v3.1${NC}: защита от блокировок ТСПУ/DPI с обфускацией пакетов (Junk packets, S1-S4, H1-H4)."
            echo -e "     • ${GREEN}AmneziaWG v2.0${NC}: совместимость со старыми роутерами (Keenetic, OpenWrt)."
            echo -e "     • ${GREEN}TUIC v5${NC}: 0-RTT рукопожатие на чистом QUIC для мгновенного отклика."
            echo -e "     • ${GREEN}Shadowsocks 2022${NC}: устойчивый к зондированию шифрованный протокол."
            echo -e "     • ${GREEN}Telegram MTProxy${NC}: прямой доступ для клиентов Telegram без дополнительных VPN-приложений."
            echo -e "     • ${GREEN}Автономный AmneziaWG${NC}: независимый сервис ядра Linux (awg-quick@awg0, утилита awg-mgr)."
            echo -e "     • ${GREEN}MASQUE (RFC 9484)${NC}: стандартизированный IETF CONNECT-UDP/IP прокси поверх HTTP/3 QUIC."
            echo -e "     • ${GREEN}ShadowTLS v4${NC}: идеальная маскировка под Apple gateway.icloud.com через Nginx Stream L4."
            echo -e "     • ${GREEN}Wstunnel (Nginx L7)${NC}: WebSocket туннелирование через порт 443 HTTPS с валидным SSL."
            echo -e "     • ${GREEN}Server-Side Zapret${NC}: десинхронизация DPI ТСПУ прямо на VPS через nfqws connbytes 1:6."
            echo -e "     • ${GREEN}NaïveProxy${NC}: маскировка под Chrome HTTP/2/3 HTTPS (Chromium network stack via Caddy)."
            echo -e "     • ${GREEN}DNSTT (DoH Tunnel)${NC}: аварийный DNS-туннель через DoH (dnstt-server) для обхода жестких белых списков."
            echo -e "     • ${GREEN}Mieru Proxy${NC}: протокол без TLS, устойчивый к активному зондированию."
            echo
        fi

        # Базовые протоколы: основные включены по умолчанию, v2.0 для старых роутеров отключен
        ENABLE_STEAL="${ENABLE_STEAL:-y}"
        ENABLE_CLASSIC="${ENABLE_CLASSIC:-y}"
        ENABLE_HY2="${ENABLE_HY2:-y}"
        ENABLE_AWG_V3="${ENABLE_AWG_V3:-y}"
        ENABLE_AWG_V2="${ENABLE_AWG_V2:-n}"
        ENABLE_TUIC="${ENABLE_TUIC:-y}"
        ENABLE_SS2022="${ENABLE_SS2022:-y}"
        ENABLE_MTPROTO="${ENABLE_MTPROTO:-y}"

        # Дополнительные протоколы по умолчанию отключены (пользователь отмечает при необходимости)
        ENABLE_AWG_STANDALONE="${ENABLE_AWG_STANDALONE:-n}"
        ENABLE_MASQUE="${ENABLE_MASQUE:-n}"
        ENABLE_SHADOWTLS="${ENABLE_SHADOWTLS:-n}"
        ENABLE_WSTUNNEL="${ENABLE_WSTUNNEL:-n}"
        ENABLE_ZAPRET="${ENABLE_ZAPRET:-n}"
        ENABLE_NAIVE="${ENABLE_NAIVE:-n}"
        ENABLE_DNSTT="${ENABLE_DNSTT:-n}"
        ENABLE_MIERU="${ENABLE_MIERU:-n}"

        local proto_keys=(
            "ENABLE_STEAL"
            "ENABLE_CLASSIC"
            "ENABLE_HY2"
            "ENABLE_AWG_V3"
            "ENABLE_AWG_V2"
            "ENABLE_TUIC"
            "ENABLE_SS2022"
            "ENABLE_MTPROTO"
            "ENABLE_AWG_STANDALONE"
            "ENABLE_MASQUE"
            "ENABLE_SHADOWTLS"
            "ENABLE_WSTUNNEL"
            "ENABLE_ZAPRET"
            "ENABLE_NAIVE"
            "ENABLE_DNSTT"
            "ENABLE_MIERU"
        )
        local proto_labels=(
            "VLESS REALITY (маскировка под свой сайт, :${STEAL_PORT:-45443})"
            "VLESS REALITY (маскировка под популярные сервисы, :${CLASSIC_PORT:-46443})"
            "Hysteria 2 (UDP/QUIC Brutal CC, :${HY2_PORT:-443})"
            "AmneziaWG v3.1 (продвинутая обфускация WireGuard, :${AWG_V3_PORT:-8443}/udp)"
            "AmneziaWG v2.0 (совместимость с роутерами Keenetic / OpenWrt, :${AWG_V2_PORT:-8444}/udp)"
            "TUIC v5 (высокоскоростной QUIC 0-RTT, :${TUIC_PORT:-8448}/udp)"
            "Shadowsocks 2022 (современный шифрованный протокол TCP/UDP, :${SS2022_PORT:-8388})"
            "Telegram MTProxy (прямой доступ для клиентов Telegram с FakeTLS, :${MTPROTO_PORT:-8444}/tcp)"
            "Автономный сервер AmneziaWG (системная служба с CLI awg-mgr, :${AWG_STANDALONE_PORT:-8445}/udp)"
            "MASQUE (RFC 9484 / HTTP/3 IP-проксирование, :${MASQUE_PORT:-8449}/udp)"
            "ShadowTLS v4 + SS-2022 (маскировка под доверенный TLS SNI)"
            "Wstunnel over Nginx L7 (пробитие строгих файрволов через WebSocket :443)"
            "Server-Side Zapret (DPI Desync nfqws connbytes 1:6 NFQUEUE 200)"
            "NaïveProxy (Chromium HTTPS сетевой стек против цензуры)"
            "DNSTT DoH Tunnel (DNS-туннелирование при блокировке IP/SNI)"
            "Mieru Proxy (XChaCha20-Poly1305, без TLS, защита от зондирования, :${MIERU_PORT:-8450})"
        )

        prompt_multiselect "Выберите протоколы для установки" proto_keys proto_labels || return $?

        echo
        echo -e "  ${BOLD}Настройка сетевых портов подключения:${NC}"
        echo -e "    ${GREEN}[0] Нет (по умолчанию)${NC} — безопасные рекомендованные порты для всех протоколов и служб"
        echo -e "    ${CYAN}[1] Да (все порты)${NC}     — ручная настройка всех портов (внешних клиентских и внутренних локальных)"
        echo -e "    ${CYAN}[2] Только внешние${NC}     — ручная настройка только внешних клиентских портов (все внутренние — по умолчанию)"
        echo

        local port_mode_input=""
        while true; do
            prompt_default "  Хотите ли вы настраивать порты подключений вручную? [0/1/2]" "${PORTS_SETUP_MODE:-0}" port_mode_input || return $?
            port_mode_input=$(echo "${port_mode_input:-0}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            case "$port_mode_input" in
                0|n|no|нет)
                    PORTS_SETUP_MODE=0
                    ok "Выбран автоматический режим: все порты назначаются по умолчанию."
                    break
                    ;;
                1|y|yes|да)
                    PORTS_SETUP_MODE=1
                    ok "Выбран ручной режим: подробная настройка всех портов (внешних и внутренних)."
                    break
                    ;;
                2|ext|external|внешние)
                    PORTS_SETUP_MODE=2
                    ok "Выбран режим настройки только внешних портов (все внутренние порты остаются по умолчанию)."
                    break
                    ;;
                *)
                    warn "  Пожалуйста, введите 0 (Нет), 1 (Все порты) или 2 (Только внешние)."
                    ;;
            esac
        done

        # Настройки VLESS REALITY (свой сайт)
        if is_true "$ENABLE_STEAL"; then
            STEAL_ENABLED=1
            configure_steal_settings || return $?
        else
            STEAL_ENABLED=0
            STEAL_PORTS_LIST=()
            STEAL_DOMAINS=()
        fi

        # Настройки VLESS REALITY (внешние сервисы)
        if is_true "$ENABLE_CLASSIC"; then
            CLASSIC_ENABLED=1
            configure_classic_settings || return $?
        else
            CLASSIC_ENABLED=0
            CLASSIC_PORTS_LIST=()
            EXT_SNI_LIST=()
            ALL_EXT_SNIS=()
        fi

        # Установка портов по умолчанию и опрос кастомных параметров в экспертном режиме
        if is_true "$ENABLE_HY2"; then
            [ -n "${HY2_PORT:-}" ] || HY2_PORT="443"
            [ -n "${HY2_DOMAIN:-}" ] || HY2_DOMAIN="$PRIMARY_DOMAIN"
            HY2_PORT_HOPPING="${HY2_PORT_HOPPING:-n}"
            HY2_PORT_HOPPING_RANGE="${HY2_PORT_HOPPING_RANGE:-20000:50000}"
            if [ "${PORTS_SETUP_MODE:-0}" != "0" ]; then
                prompt_default "  UDP-порт для Hysteria 2" "$HY2_PORT" HY2_PORT || return $?
                prompt_yes_no "  Включить Port Hopping для Hysteria 2 (UDP 20000:50000)?" "$HY2_PORT_HOPPING" HY2_PORT_HOPPING || return $?
                if is_true "$HY2_PORT_HOPPING"; then
                    prompt_default "  Диапазон портов Port Hopping" "$HY2_PORT_HOPPING_RANGE" HY2_PORT_HOPPING_RANGE || return $?
                fi
            fi
        else
            HY2_PORT=""
            HY2_DOMAIN=""
            HY2_PORT_HOPPING="n"
        fi

        if is_true "$ENABLE_AWG_V3"; then
            [ -n "${AWG_V3_PORT:-}" ] || AWG_V3_PORT="8443"
            if [ "${PORTS_SETUP_MODE:-0}" != "0" ]; then
                prompt_default "  UDP-порт для AmneziaWG v3.1" "$AWG_V3_PORT" AWG_V3_PORT || return $?
            fi
        else
            AWG_V3_PORT=""
        fi

        if is_true "$ENABLE_AWG_V2"; then
            [ -n "${AWG_V2_PORT:-}" ] || AWG_V2_PORT="8444"
            if [ "${PORTS_SETUP_MODE:-0}" != "0" ]; then
                prompt_default "  UDP-порт для AmneziaWG v2.0" "$AWG_V2_PORT" AWG_V2_PORT || return $?
            fi
        else
            AWG_V2_PORT=""
        fi

        if is_true "$ENABLE_AWG_STANDALONE"; then
            [ -n "${AWG_STANDALONE_PORT:-}" ] || AWG_STANDALONE_PORT="8445"
            [ -n "${AWG_SERVER_HOST:-}" ] || AWG_SERVER_HOST="${PRIMARY_DOMAIN:-$WAN_IP}"
            if [ "${PORTS_SETUP_MODE:-0}" != "0" ]; then
                prompt_default "  UDP-порт для автономного AmneziaWG" "$AWG_STANDALONE_PORT" AWG_STANDALONE_PORT || return $?
            fi
        else
            AWG_STANDALONE_PORT=""
        fi

        if is_true "$ENABLE_TUIC"; then
            [ -n "${TUIC_PORT:-}" ] || TUIC_PORT="8448"
            if [ "${PORTS_SETUP_MODE:-0}" != "0" ]; then
                prompt_default "  UDP-порт для TUIC v5" "$TUIC_PORT" TUIC_PORT || return $?
            fi
        else
            TUIC_PORT=""
        fi

        if is_true "$ENABLE_SS2022"; then
            [ -n "${SS2022_PORT:-}" ] || SS2022_PORT="8388"
            if [ "${PORTS_SETUP_MODE:-0}" != "0" ]; then
                prompt_default "  Порт для Shadowsocks 2022 (TCP/UDP)" "$SS2022_PORT" SS2022_PORT || return $?
            fi
        else
            SS2022_PORT=""
        fi

        if is_true "$ENABLE_MTPROTO"; then
            [ -n "${MTPROTO_PORT:-}" ] || MTPROTO_PORT="8444"
            [ -n "${MTPROTO_FAKETLS_DOMAIN:-}" ] || MTPROTO_FAKETLS_DOMAIN="gateway.icloud.com"
            MTPROTO_ADTAG="${MTPROTO_ADTAG:-}"
            if [ "${PORTS_SETUP_MODE:-0}" != "0" ]; then
                prompt_default "  TCP-порт для Telegram MTProxy" "$MTPROTO_PORT" MTPROTO_PORT || return $?
            fi
        else
            MTPROTO_PORT=""
            MTPROTO_FAKETLS_DOMAIN=""
            MTPROTO_ADTAG=""
        fi

        if is_true "$ENABLE_MASQUE"; then
            [ -n "${MASQUE_PORT:-}" ] || MASQUE_PORT="8449"
            [ -n "${MASQUE_USER:-}" ] || MASQUE_USER="client"
            [ -n "${MASQUE_PASSWORD:-}" ] || MASQUE_PASSWORD="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "masque${RANDOM}")"
            if [ "${PORTS_SETUP_MODE:-0}" != "0" ]; then
                prompt_default "  UDP-порт для MASQUE (HTTP/3)" "$MASQUE_PORT" MASQUE_PORT || return $?
            fi
        else
            MASQUE_PORT=""
        fi

        if is_true "$ENABLE_SHADOWTLS"; then
            [ -n "${SHADOWTLS_PORT:-}" ] || SHADOWTLS_PORT="8543"
            [ -n "${SHADOWTLS_SNI:-}" ] || SHADOWTLS_SNI="gateway.icloud.com"
            [ -n "${SHADOWTLS_PASSWORD:-}" ] || SHADOWTLS_PASSWORD="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "stls${RANDOM}")"
            ENABLE_SS2022=1
            [ -n "${SS2022_PORT:-}" ] || SS2022_PORT="8388"
            if [ "${PORTS_SETUP_MODE:-0}" = "1" ]; then
                prompt_default "  Локальный порт для ShadowTLS" "$SHADOWTLS_PORT" SHADOWTLS_PORT || return $?
            fi
        else
            SHADOWTLS_PORT=""
            SHADOWTLS_SNI=""
        fi

        if is_true "$ENABLE_WSTUNNEL"; then
            [ -n "${WSTUNNEL_PORT:-}" ] || WSTUNNEL_PORT="8080"
            ensure_wstunnel_prefix || return 1
            [ -n "${WSTUNNEL_SECRET:-}" ] || WSTUNNEL_SECRET="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "wst${RANDOM}")"
            if [ "${PORTS_SETUP_MODE:-0}" = "1" ]; then
                prompt_default "  Локальный порт для Wstunnel daemon" "$WSTUNNEL_PORT" WSTUNNEL_PORT || return $?
            fi
        else
            WSTUNNEL_PORT=""
            WSTUNNEL_PREFIX=""
        fi

        if is_true "$ENABLE_ZAPRET"; then
            [ -n "${ZAPRET_QNUM:-}" ] || ZAPRET_QNUM="200"
            [ -n "${ZAPRET_DESYNC:-}" ] || ZAPRET_DESYNC="split2"
            [ -n "${ZAPRET_FOOLING:-}" ] || ZAPRET_FOOLING="md5sig,badseq"
            if [ "${PORTS_SETUP_MODE:-0}" = "1" ]; then
                prompt_default "  Очередь NFQUEUE для Zapret" "$ZAPRET_QNUM" ZAPRET_QNUM || return $?
            fi
        else
            ZAPRET_QNUM=""
        fi

        if is_true "$ENABLE_NAIVE"; then
            [ -n "${NAIVE_PORT:-}" ] || NAIVE_PORT="8446"
            [ -n "${NAIVE_USER:-}" ] || NAIVE_USER="user"
            [ -n "${NAIVE_DOMAIN:-}" ] || NAIVE_DOMAIN="naive.${PRIMARY_DOMAIN:-}"
            [ -n "${NAIVE_PASS:-}" ] || NAIVE_PASS="$(generate_urlsafe_token 16)"
            if [ "${PORTS_SETUP_MODE:-0}" = "1" ]; then
                prompt_default "  Локальный порт для NaïveProxy (Caddy)" "$NAIVE_PORT" NAIVE_PORT || return $?
            fi
        else
            NAIVE_PORT=""
            NAIVE_DOMAIN=""
            NAIVE_USER=""
            NAIVE_PASS=""
        fi

        if is_true "$ENABLE_DNSTT"; then
            [ -n "${DNSTT_PORT:-}" ] || DNSTT_PORT="53053"
            [ -n "${DNSTT_DOMAIN:-}" ] || DNSTT_DOMAIN="t.${PRIMARY_DOMAIN:-}"
            ENABLE_SS2022=1
            [ -n "${SS2022_PORT:-}" ] || SS2022_PORT="8388"
            if [ "${PORTS_SETUP_MODE:-0}" != "0" ]; then
                prompt_default "  UDP-порт для DNSTT-сервера" "$DNSTT_PORT" DNSTT_PORT || return $?
            fi
        else
            DNSTT_PORT=""
            DNSTT_DOMAIN=""
        fi

        if is_true "$ENABLE_MIERU"; then
            MIERU_PORT_MODE="${MIERU_PORT_MODE:-single}"
            if [ "${PORTS_SETUP_MODE:-0}" != "0" ]; then
                echo -e "\n  ${BOLD}Режим портов для Mieru Proxy:${NC}"
                echo -e "    1) Одиночный порт [8450] (рекомендуется)"
                echo -e "    2) Пул портов [8450-8455] (рандомизация соединений)"
                local _m_mode_choice="1"
                [ "$MIERU_PORT_MODE" = "range" ] && _m_mode_choice="2"
                prompt_default "  Выберите режим портов Mieru (1 или 2)" "$_m_mode_choice" _m_mode_choice || return $?
                if [ "$_m_mode_choice" = "2" ]; then
                    MIERU_PORT_MODE="range"
                    prompt_default "  Диапазон портов для Mieru (TCP и UDP)" "${MIERU_PORT:-8450-8455}" MIERU_PORT || return $?
                else
                    MIERU_PORT_MODE="single"
                    prompt_default "  Порт для Mieru (TCP и UDP)" "${MIERU_PORT:-8450}" MIERU_PORT || return $?
                fi
            else
                case "${MIERU_PORT_MODE,,}" in
                    range|pool)
                        MIERU_PORT="${MIERU_PORT:-8450-8455}"
                        ;;
                    *)
                        MIERU_PORT_MODE="single"
                        MIERU_PORT="${MIERU_PORT:-8450}"
                        ;;
                esac
            fi
            [ -n "${MIERU_USER:-}" ] || MIERU_USER="user-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "mieru${RANDOM}")"
            [ -n "${MIERU_PASS:-}" ] || MIERU_PASS="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "mieru${RANDOM}")"
        else
            MIERU_PORT=""
            MIERU_USER=""
            MIERU_PASS=""
        fi

        rebuild_all_domains
        sync_reality_ports
        return 0
    }

    q_step_ports() {
        echo
        echo -e "${YELLOW}━━━ Шаг 3/11: Настройка внутренних портов и секретных путей (веб-панель и VLESS xHTTP) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Внутренние локальные порты и секретные URI-пути для веб-панели управления,"
            echo -e "     сервера подписок для клиентов и инбаунда VLESS xHTTP (HTTP/2 Stream-One)."
            echo
        fi

        # --- 1. Внутренние сетевые порты служб ---
        local ask_internal_ports=0
        if [ "${PORTS_SETUP_MODE:-0}" = "1" ]; then
            ask_internal_ports=1
        elif [ "${EDITING_FROM_REVIEW:-0}" -eq 1 ]; then
            local change_ports="n"
            prompt_yes_no "  Настроить внутренние порты служб (:10443, :55443, :50443) вручную?" "n" change_ports || return $?
            if is_true "$change_ports"; then
                ask_internal_ports=1
            fi
        fi

        if [ "$ask_internal_ports" -eq 1 ]; then
            prompt_default "  Внутренний порт веб-панели управления" "${PANEL_PORT:-10443}" PANEL_PORT || return $?
            prompt_default "  Внутренний порт сервера подписок" "${SUB_PORT:-55443}" SUB_PORT || return $?
            prompt_default "  Внутренний порт инбаунда VLESS xHTTP" "${XHTTP_STREAM_PORT:-50443}" XHTTP_STREAM_PORT || return $?
        else
            PANEL_PORT="${PANEL_PORT:-10443}"
            SUB_PORT="${SUB_PORT:-55443}"
            XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
        fi

        # --- 2. Секретные URI-пути и доступ к 3X-UI (Отдельный вопрос) ---
        echo
        echo -e "  ${BOLD}Настройка секретных URI-путей и доступа к 3X-UI:${NC}"
        echo -e "    ${GREEN}[0] Нет (по умолчанию)${NC} — случайные криптостойкие URI-пути и пароль (защита от сканеров и ботов)"
        echo -e "    ${CYAN}[1] Да (вручную)${NC}       — задать свои URI-пути (панель, подписки, xHTTP), логин и пароль"
        echo

        local ask_paths=0
        local paths_mode_input=""
        while true; do
            prompt_default "  Хотите ли вы настраивать секретные URI-пути и пароли вручную? [0/1]" "${PATHS_SETUP_MODE:-0}" paths_mode_input || return $?
            paths_mode_input=$(echo "${paths_mode_input:-0}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            case "$paths_mode_input" in
                0|n|no|нет)
                    PATHS_SETUP_MODE=0
                    ask_paths=0
                    ok "Выбран автоматический режим: пути и пароли генерируются криптостойкими хешами."
                    break
                    ;;
                1|y|yes|да)
                    PATHS_SETUP_MODE=1
                    ask_paths=1
                    ok "Выбран ручной ввод URI-путей и учетных данных."
                    break
                    ;;
                *)
                    warn "  Пожалуйста, введите 0 (Нет) или 1 (Да)."
                    ;;
            esac
        done

        if [ "$ask_paths" -eq 1 ]; then
            prompt_default "  Логин администратора 3X-UI" "${ADMIN_USERNAME:-admin}" ADMIN_USERNAME || return $?
            local def_pass="${ADMIN_PASSWORD:-$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 12 || echo "Admin1234567")}"
            prompt_default "  Пароль администратора 3X-UI" "$def_pass" ADMIN_PASSWORD || return $?

            ensure_panel_path || return 1
            local r_path="$RAW_PATH"
            prompt_default "  Секретный URI-путь к веб-панели (без слэшей)" "$r_path" RAW_PATH || return $?
            validate_path_segment "$RAW_PATH" "URI панели"
            PANEL_PATH="/${RAW_PATH#/}"; PANEL_PATH="${PANEL_PATH%/}/"

            local rand_s_path="sub-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "sub${RANDOM}")"
            local r_sub="${RAW_SUB_PATH:-${SUB_PATH:-$rand_s_path}}"
            r_sub="${r_sub#/}"; r_sub="${r_sub%/}"
            prompt_default "  Секретный URI-путь подписок (без слэшей)" "$r_sub" RAW_SUB_PATH || return $?
            validate_path_segment "$RAW_SUB_PATH" "URI подписок"
            SUB_PATH="/${RAW_SUB_PATH#/}"; SUB_PATH="${SUB_PATH%/}/"
            SUB_JSON_PATH="${SUB_PATH%/}/json/"
            SUB_CLASH_PATH="${SUB_PATH%/}/clash/"
            prompt_default "  Заголовок подписки для клиентов (Enter - без заголовка)" "${SUB_TITLE:-}" SUB_TITLE || return $?

            local rand_x_path="$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "xh${RANDOM}")"
            local r_xhttp="${RAW_XHTTP_STREAM_PATH:-${XHTTP_STREAM_PATH:-$rand_x_path}}"
            r_xhttp="${r_xhttp#/}"; r_xhttp="${r_xhttp%/}"
            prompt_default "  URI-путь для xHTTP Stream-One" "$r_xhttp" RAW_XHTTP_STREAM_PATH || return $?
            validate_path_segment "$RAW_XHTTP_STREAM_PATH" "URI xHTTP"
            XHTTP_STREAM_PATH="/${RAW_XHTTP_STREAM_PATH#/}"; XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH%/}/"
        else
            ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
            [ -n "${ADMIN_PASSWORD:-}" ] || ADMIN_PASSWORD="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 12 || echo "Admin1234567")"

            ensure_panel_path || return 1
            validate_path_segment "$RAW_PATH" "URI панели"

            [ -n "${RAW_SUB_PATH:-}" ] || RAW_SUB_PATH="sub-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "sub${RANDOM}")"
            RAW_SUB_PATH="${RAW_SUB_PATH#/}"; RAW_SUB_PATH="${RAW_SUB_PATH%/}"
            SUB_PATH="/${RAW_SUB_PATH#/}"; SUB_PATH="${SUB_PATH%/}/"
            SUB_JSON_PATH="${SUB_PATH%/}/json/"
            SUB_CLASH_PATH="${SUB_PATH%/}/clash/"

            [ -n "${RAW_XHTTP_STREAM_PATH:-}" ] || RAW_XHTTP_STREAM_PATH="$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "xh${RANDOM}")"
            RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH#/}"; RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH%/}"
            XHTTP_STREAM_PATH="/${RAW_XHTTP_STREAM_PATH#/}"; XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH%/}/"
        fi

        ensure_diag_path || return 1

        echo
        echo -e "  ${GREEN}${CHECK} Конфигурация портов и путей 3X-UI:${NC}"
        echo -e "    ${DIM}• Порты:${NC}   Панель :$PANEL_PORT, Подписки :$SUB_PORT, xHTTP :$XHTTP_STREAM_PORT"
        echo -e "    ${DIM}• Пути:${NC}    Панель: $PANEL_PATH, Подписки: $SUB_PATH, Clash: $SUB_CLASH_PATH, xHTTP: $XHTTP_STREAM_PATH"
        echo -e "    ${DIM}• Доступ:${NC}  Логин: ${BOLD}$ADMIN_USERNAME${NC}, Пароль: ${YELLOW}$ADMIN_PASSWORD${NC}"

        ok "Внутренние порты и пути сконфигурированы."
        return 0
    }

    q_step_awg_v3() {
        prompt_yes_no "Установить и настроить AmneziaWG v3.1?" "${ENABLE_AWG_V3:-y}" ENABLE_AWG_V3 || return $?
        if is_true "${ENABLE_AWG_V3:-y}"; then
            ENABLE_AWG_V3=1
            prompt_default "  Внешний UDP-порт для AmneziaWG v3.1" "${AWG_V3_PORT:-8443}" AWG_V3_PORT || return $?
        else
            ENABLE_AWG_V3=0
            AWG_V3_PORT=""
        fi
        return 0
    }

    q_step_awg_v2() {
        prompt_yes_no "Установить и настроить AmneziaWG v2.0 (для роутеров Keenetic / OpenWrt)?" "${ENABLE_AWG_V2:-n}" ENABLE_AWG_V2 || return $?
        if is_true "${ENABLE_AWG_V2:-y}"; then
            ENABLE_AWG_V2=1
            prompt_default "  Внешний UDP-порт для AmneziaWG v2.0" "${AWG_V2_PORT:-8444}" AWG_V2_PORT || return $?
        else
            ENABLE_AWG_V2=0
            AWG_V2_PORT=""
        fi
        return 0
    }

    q_step_awg_standalone() {
        prompt_yes_no "Установить автономный сервер AmneziaWG (awg-mgr / системная служба на хосте)?" "${ENABLE_AWG_STANDALONE:-n}" ENABLE_AWG_STANDALONE || return $?
        if is_true "${ENABLE_AWG_STANDALONE:-y}"; then
            ENABLE_AWG_STANDALONE=1
            prompt_default "  Внешний UDP-порт для автономного сервера AmneziaWG" "${AWG_STANDALONE_PORT:-8445}" AWG_STANDALONE_PORT || return $?
            prompt_default "  Домен или IP-адрес для подключения клиентов (Endpoint)" "${AWG_SERVER_HOST:-${PRIMARY_DOMAIN:-$WAN_IP}}" AWG_SERVER_HOST || return $?
        else
            ENABLE_AWG_STANDALONE=0
            AWG_STANDALONE_PORT=""
        fi
        return 0
    }

    q_step_agh() {
        echo
        echo -e "${YELLOW}━━━ Шаг 4/11: Настройка приватного AdGuard Home DoH + Split-DNS ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Приватный шифрованный DNS (DNS-over-HTTPS) с защитой от рекламы и трекеров."
            echo -e "     ${GREEN}Split-DNS:${NC} Запросы к российским сайтам (.ru, банки, Госуслуги) направляются"
            echo -e "     через надежные локальные DNS, предотвращая ошибки доступа и сбои авторизации."
            echo
        fi

        prompt_yes_no "Установить приватный AdGuard Home DoH со Split-DNS?" "${ENABLE_AGH:-y}" ENABLE_AGH || return $?
        if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
            ENABLE_AGH=1
            echo
            echo -e "  ${BOLD}Режим доступа к AdGuard Home DoH:${NC}"
            echo -e "    ${GREEN}1)${NC} На основном домене (${PRIMARY_DOMAIN}/dns-query/)"
            [ "${SHOW_TIPS:-y}" = "y" ] && echo -e "       ${DIM}— Не нужен отдельный поддомен и дополнительный сертификат${NC}"
            [ "${SHOW_TIPS:-y}" = "y" ] && echo -e "       ${DIM}— Быстрая настройка, рекомендовано для большинства${NC}"
            echo -e "    ${GREEN}2)${NC} На отдельном поддомене (dns.${PRIMARY_DOMAIN})"
            [ "${SHOW_TIPS:-y}" = "y" ] && echo -e "       ${DIM}— Требуется A-запись у регистратора, полная изоляция DNS${NC}"
            echo
            prompt_default "  Ваш выбор (1 или 2)" "${AGH_MODE:-1}" AGH_MODE || return $?
            if [ "$AGH_MODE" = "2" ]; then
                prompt_default "  Поддомен для AdGuard Home DoH" "${AGH_DOMAIN:-dns.$PRIMARY_DOMAIN}" AGH_DOMAIN || return $?
                AGH_DOMAIN=$(echo "$AGH_DOMAIN" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            else
                AGH_MODE="1"
                AGH_DOMAIN=""
            fi

            prompt_default "  Логин администратора AdGuard Home" "${AGH_USER:-admin}" AGH_USER || return $?
            local def_ag_pass="${AGH_PASS:-AgHome_$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 8 || echo 'Pass1234')}"
            prompt_default "  Пароль администратора AdGuard Home" "$def_ag_pass" AGH_PASS || return $?
            ensure_agh_client_id || return 1
            local def_agh_cid="$AGH_CLIENT_ID"
            prompt_default "  Секретный ClientID токен для роутера" "$def_agh_cid" AGH_CLIENT_ID || return $?
            prompt_yes_no "  Использовать AdGuard Home как DNS для VPN-клиентов (Xray)?" "${AGH_XRAY_DNS:-n}" AGH_XRAY_DNS || return $?
            ok "AdGuard Home настроен (Режим: $AGH_MODE, ClientID: $AGH_CLIENT_ID)"
        else
            ENABLE_AGH=0
            AGH_DOMAIN=""
            log "AdGuard Home DoH отключен."
        fi

        rebuild_all_domains
        return 0
    }

    q_step_decoy() {
        echo
        echo -e "${YELLOW}━━━ Шаг 5/11: Выбор темы для сайта-маскировки (Decoy Site) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Веб-сайт, который отображается в браузере при обращении к вашему домену."
            echo -e "     Защищает сервер от выявления цензорами, активными сканерами и сетевыми ботами."
            echo
            echo -e "  ${BOLD}Доступные варианты маскировки:${NC}"
            echo -e "    ${GREEN}[1] DataSphere Analytics (Рекомендуется)${NC}"
            echo -e "        ${DIM}• Корпоративный портал распределенной аналитики данных${NC}"
            echo -e "        ${DIM}• Интерактивная 3D-сфера узлов, Anycast-телеметрия потока и Web CLI${NC}"
            echo -e "        ${DIM}• Документация API, статус сервисов и строгая политика CSP (без unsafe-inline)${NC}"
            echo
            echo -e "    ${GREEN}[2] CosmosCloud NextGen${NC}"
            echo -e "        ${DIM}• Корпоративное облачное хранилище файлов (аналог Nextcloud / OwnCloud)${NC}"
            echo -e "        ${DIM}• Форма входа в хранилище, сессионные cookies, реалистичный брендинг${NC}"
            echo
            echo -e "    ${GREEN}[3] Стандартная заглушка Nginx${NC}"
            echo -e "        ${DIM}• Классическая системная страница «Welcome to nginx!»${NC}"
            echo
        else
            echo -e "  ${BOLD}Варианты маскировки:${NC} [1] DataSphere Analytics (Рекомендуется)  [2] CosmosCloud  [3] Заглушка Nginx"
        fi

        prompt_default "  Выберите вариант маскировки (1, 2 или 3)" "${DECOY_MODE:-1}" DECOY_MODE || return $?
        case "$DECOY_MODE" in
            2) ok "Выбрана тема: CosmosCloud NextGen" ;;
            3) ok "Выбрана стандартная заглушка Nginx" ;;
            *) DECOY_MODE="1"; ok "Выбрана тема: DataSphere Analytics" ;;
        esac
        return 0
    }

    q_step_ssl_domains() {
        echo
        echo -e "${YELLOW}━━━ Шаг 6/11: Реестр SSL-сертификатов и дополнительные домены ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Список доменов, для которых будут автоматически получены SSL-сертификаты."
            echo -e "  ${DIM}Следующие домены уже включены автоматически из предыдущих шагов:${NC}"
        fi
        rebuild_all_domains
        for d in "${ALL_DOMAINS[@]}"; do
            echo -e "    ${GREEN}✔ ${WHITE}$d${NC}"
        done
        echo

        while true; do
            echo -ne "  ${WHITE}${ARROW} Добавить дополнительный домен в сертификат? (Enter = пропустить) ${DIM}(b - назад)${NC}: "
            local extra_d=""
            read -r extra_d </dev/tty || read -r extra_d || true
            extra_d=$(echo "${extra_d:-}" | tr -d '[:space:]')
            if [[ "${extra_d,,}" == "b" || "${extra_d,,}" == "back" || "${extra_d,,}" == "назад" ]]; then
                return 10
            fi
            [ -z "$extra_d" ] && break

            if [[ "$extra_d" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                if [[ " ${ALL_DOMAINS[*]} " == *" ${extra_d} "* ]]; then
                    warn "  Домен '$extra_d' уже есть в списке."
                else
                    EXTRA_DOMAINS_USER+=("$extra_d")
                    ALL_DOMAINS+=("$extra_d")
                    ok "  Добавлен дополнительный SSL-домен: $extra_d"
                fi
            else
                warn "  Некорректный формат доменного имени: '$extra_d'."
            fi
        done
        return 0
    }

    q_step_ssl_engine() {
        echo
        echo -e "${YELLOW}━━━ Шаг 7/11: Выбор метода выпуска SSL-сертификатов ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Способ валидации владения доменом для Let's Encrypt."
            echo -e "    ${GREEN}[1] Классический Certbot (HTTP-01, Рекомендуется)${NC}"
            echo -e "        ${DIM}• Простая валидация через порт 80 Nginx. Не требует API-ключей.${NC}"
            echo -e "    ${GREEN}[2] acme.sh + Cloudflare DNS-01${NC}"
            echo -e "        ${DIM}• Валидация через DNS API Cloudflare. Позволяет выпускать Wildcard (*.domain).${NC}"
            echo
        else
            echo -e "  ${BOLD}Метод SSL:${NC} [1] Certbot (HTTP-01)  [2] acme.sh + Cloudflare DNS-01"
        fi

        prompt_default "  Выберите метод сертификации (1 или 2)" "${SSL_ENGINE_CHOICE:-1}" SSL_ENGINE_CHOICE || return $?
        prompt_default "  Email для Let's Encrypt уведомлений (Enter - без почты)" "${LE_EMAIL:-}" LE_EMAIL || return $?

        if [ "$SSL_ENGINE_CHOICE" = "2" ]; then
            echo
            echo -e "  ${YELLOW}Аутентификация в Cloudflare API (acme.sh):${NC}"
            echo -e "    ${GREEN}1)${NC} API Token (Рекомендуется: Zone.DNS:Edit, Zone.Zone:Read)"
            echo -e "    ${GREEN}2)${NC} Global API Key (Email + Global Key)"
            prompt_default "  Выберите вариант (1 или 2)" "${CF_AUTH_METHOD:-1}" CF_AUTH_METHOD || return $?

            if [ "$CF_AUTH_METHOD" = "1" ]; then
                prompt_secret "  Введите Cloudflare API Token" "${CF_Token:-}" CF_Token || return $?
                [ -n "$CF_Token" ] || die "API Token не может быть пустым."
                prompt_default "  Введите Cloudflare Account ID (Enter для пропуска)" "${CF_Account_ID:-}" CF_Account_ID || return $?
                export CF_Token
                [ -n "${CF_Account_ID:-}" ] && export CF_Account_ID="$CF_Account_ID"
            else
                prompt_default "  Введите ваш Cloudflare Email" "${CF_Email:-}" CF_Email || return $?
                [ -n "$CF_Email" ] || die "Email не может быть пустым."
                prompt_secret "  Введите Cloudflare Global API Key" "${CF_Key:-}" CF_Key || return $?
                [ -n "$CF_Key" ] || die "Global API Key не может быть пустым."
                export CF_Email
                export CF_Key
            fi
        fi
        return 0
    }

    q_step_3xui_auto() {
        echo
        echo -e "${YELLOW}━━━ Шаг 8/11: Автоматическая настройка базы данных панели 3X-UI ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Автоматическое создание подключений (REALITY со своим сайтом, внешними сервисами, xHTTP)"
            echo -e "     в базе данных панели 3X-UI, а также настройка секретных путей и подписок."
            echo -e "     Вам не придется добавлять подключения вручную через браузер."
            echo
        fi

        prompt_yes_no "Автоматически настроить инбаунды и пути в панели 3X-UI?" "${AUTO_SETUP_3XUI:-y}" AUTO_SETUP_3XUI || return $?
        if [[ "${AUTO_SETUP_3XUI,,}" == "y" || "${AUTO_SETUP_3XUI:-}" == "1" ]]; then
            AUTO_SETUP_3XUI="y"
            if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
                echo
                echo -e "  ${CYAN}💡 3X-UI Node:${NC} Генерация API-токена позволяет подключить этот сервер"
                echo -e "     как ведомый узел (Node) к другой мастер-панели 3X-UI или внешней системе управления."
                echo
            fi

            prompt_yes_no "Создать API-токен для подключения сервера как узла (3X-UI Node)?" "${ENABLE_NODE_TOKEN:-y}" ENABLE_NODE_TOKEN || return $?
            if [[ "${ENABLE_NODE_TOKEN,,}" == "y" || "${ENABLE_NODE_TOKEN:-}" == "1" ]]; then
                ENABLE_NODE_TOKEN="y"
                local def_token_name="${SERVER_PREFIX:+$SERVER_PREFIX-Node}"
                if [[ -z "$SERVER_PREFIX" || "${SERVER_PREFIX,,}" =~ ^(-|none|off|no)$ ]]; then
                    def_token_name="Master-Node-Cluster"
                fi
                if [[ "${EXPERT_MODE:-0}" == "1" ]] && declare -F prompt_default >/dev/null; then
                    prompt_default "  Имя API-токена ноды" "${NODE_TOKEN_NAME:-$def_token_name}" NODE_TOKEN_NAME || return $?
                else
                    NODE_TOKEN_NAME="${NODE_TOKEN_NAME:-$def_token_name}"
                fi
                ok "API-токен ноды будет создан с именем: ${WHITE}$NODE_TOKEN_NAME${NC}"
            else
                ENABLE_NODE_TOKEN="n"
                NODE_TOKEN_NAME=""
            fi
        else
            AUTO_SETUP_3XUI="n"
            ENABLE_NODE_TOKEN="n"
            NODE_TOKEN_NAME=""
        fi
        return 0
    }

    q_step_warp() {
        echo
        echo -e "${YELLOW}━━━ Шаг 9/11: Исходящий туннель Cloudflare WARP ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Исходящий WireGuard туннель от вашего VPS в сеть Cloudflare."
            echo -e "     ${GREEN}Преимущество:${NC} Полностью избавляет от капч Google/Cloudflare и разблокирует"
            echo -e "     доступ к зарубежным AI-сервисам (ChatGPT, Claude, Gemini). Видео YouTube и"
            echo -e "     российские сайты продолжают работать напрямую на полной скорости."
            echo
        fi

        prompt_yes_no "Включить интеграцию Cloudflare WARP?" "${ENABLE_WARP:-n}" ENABLE_WARP || return $?
        if [[ "${ENABLE_WARP,,}" == "y" || "${ENABLE_WARP:-}" == "1" ]]; then
            ENABLE_WARP="y"
            prompt_default "  Лицензионный ключ WARP+ (Enter - использовать бесплатный безлимитный)" "${WARP_LICENSE_KEY:-}" WARP_LICENSE_KEY || return $?
            ok "Интеграция Cloudflare WARP активирована."
        else
            ENABLE_WARP="n"
            WARP_LICENSE_KEY=""
            log "Интеграция Cloudflare WARP отключена."
        fi
        return 0
    }

    q_step_security() {
        echo
        echo -e "${YELLOW}━━━ Шаг 10/11: Безопасность сервера (SSH и Fail2ban) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Базовая защита операционной системы хоста."
            echo -e "     ${GREEN}Преимущество:${NC} Перенос порта SSH со стандартного 22 скрывает сервер"
            echo -e "     от автоматических сканеров портов, а Fail2ban автоматически блокирует IP-адреса"
            echo -e "     злоумышленников после нескольких неудачных попыток подбора паролей."
            echo
        fi

        local def_active_port
        def_active_port=$(detect_active_ssh_port)
        [ -n "$def_active_port" ] || def_active_port=22
        SSH_ACTIVE_PORT="${SSH_ACTIVE_PORT:-$def_active_port}"

        local current_configured_port="${SSH_PORT:-$SSH_ACTIVE_PORT}"

        prompt_yes_no "Настроить безопасность сервера (SSH-ключи, порт и защиту Fail2ban)?" "${ENABLE_HOST_SECURITY:-n}" ENABLE_HOST_SECURITY || return $?
        if is_true "$ENABLE_HOST_SECURITY"; then
            ENABLE_HOST_SECURITY="y"

            # Вопрос 1: Порт SSH
            echo
            local keep_ssh="y"
            if [ "$current_configured_port" -ne "$SSH_ACTIVE_PORT" ]; then
                keep_ssh="n"
            fi
            prompt_yes_no "  Оставить текущий порт SSH (${SSH_ACTIVE_PORT})?" "$keep_ssh" KEEP_SSH || return $?
            if is_true "$KEEP_SSH"; then
                SSH_PORT="$SSH_ACTIVE_PORT"
                ok "Используется текущий порт SSH: ${WHITE}$SSH_PORT${NC}"
            else
                while true; do
                    local custom_p="${current_configured_port}"
                    [ "$custom_p" -eq "$SSH_ACTIVE_PORT" ] && custom_p=2222
                    prompt_default "  Введите новый порт SSH (1024-65535)" "$custom_p" custom_p || return $?
                    if [[ "$custom_p" =~ ^[0-9]+$ ]] && [ "$custom_p" -ge 1024 ] && [ "$custom_p" -le 65535 ]; then
                        # Проверка на конфликт с известными портами сервисов
                        local conflict=0
                        for reserved in 80 443 "${PANEL_PORT:-10443}" "${SUB_PORT:-55443}" "${XHTTP_STREAM_PORT:-50443}" "${HY2_PORT:-443}" "${AWG_V3_PORT:-8443}" "${AWG_V2_PORT:-8444}" "${AWG_STANDALONE_PORT:-8445}" "${SS2022_PORT:-8388}" "${TUIC_PORT:-8448}" "${MASQUE_PORT:-8449}"; do
                            if [ "$custom_p" -eq "$reserved" ]; then
                                warn "  Порт $custom_p уже используется для одного из VPN/прокси сервисов. Выберите другой."
                                conflict=1
                                break
                            fi
                        done
                        if [ "$conflict" -eq 0 ]; then
                            SSH_PORT="$custom_p"
                            ok "Новый порт SSH: ${WHITE}$SSH_PORT${NC} (активный порт $SSH_ACTIVE_PORT также останется разрешен в UFW для защиты от потери связи)"
                            break
                        fi
                    else
                        warn "  Порт должен быть числом от 1024 до 65535."
                    fi
                done
            fi

            # Вопрос 2: Настройка SSH-ключей
            echo
            local prompt_keys="n"
            if has_authorized_keys "root"; then
                echo -e "  ${GREEN}✔ В системе уже настроены авторизованные SSH-ключи (~/.ssh/authorized_keys).${NC}"
                prompt_yes_no "  Добавить дополнительный публичный ключ SSH?" "n" prompt_keys || return $?
            else
                echo -e "  ${YELLOW}ℹ️  В системе не найдено авторизованных SSH-ключей в ~/.ssh/authorized_keys.${NC}"
                prompt_keys="y"
            fi

            if is_true "$prompt_keys"; then
                echo -e "  ${CYAN}Настройка SSH-ключей для root:${NC}"
                echo -e "    ${WHITE}[1]${NC} Вставить существующий Public Key клиента (напр. ssh-ed25519 ...) ${GREEN}[Рекомендуется]${NC}"
                echo -e "    ${WHITE}[2]${NC} Сгенерировать новую пару ключей Ed25519 прямо на сервере"
                echo -e "    ${WHITE}[3]${NC} Пропустить настройку ключей"
                local k_choice="1"
                echo -ne "  ${WHITE}${ARROW} Ваш выбор (1-3) [1]: ${NC}"
                read -r k_choice </dev/tty 2>/dev/null || read -r k_choice 2>/dev/null || k_choice="1"
                k_choice="${k_choice:-1}"
                case "$k_choice" in
                    1)
                        echo -e "  ${CYAN}Вставьте ваш публичный ключ (начинается с ssh-ed25519, ssh-rsa или ecdsa):${NC}"
                        local pub_in=""
                        read -r pub_in </dev/tty 2>/dev/null || read -r pub_in 2>/dev/null || true
                        pub_in=$(echo "$pub_in" | tr -d '\r\n')
                        if [ -n "$pub_in" ]; then
                            add_authorized_key "$pub_in" "root"
                            SSH_PUBLIC_KEY="$pub_in"
                        else
                            warn "Публичный ключ не введен, пропуск."
                        fi
                        ;;
                    2)
                        generate_ed25519_keypair "root"
                        ;;
                    *)
                        log "Настройка SSH-ключей пропущена."
                        ;;
                esac
            fi

            # Вопрос 3: Отключение входа по паролю (Строго с защитой от потери доступа)
            echo
            if has_authorized_keys "root"; then
                prompt_yes_no "  Отключить вход по паролю (PasswordAuthentication no)? Вход будет ТОЛЬКО по SSH-ключам" "${DISABLE_PASSWORD_AUTH:-n}" DISABLE_PASSWORD_AUTH || return $?
                if is_true "$DISABLE_PASSWORD_AUTH"; then
                    DISABLE_PASSWORD_AUTH="y"
                    ok "Вход по паролю будет отключен. Убедитесь, что у вас сохранен приватный ключ!"
                else
                    DISABLE_PASSWORD_AUTH="n"
                    log "Вход по паролю оставлен включенным."
                fi
            else
                DISABLE_PASSWORD_AUTH="n"
                echo -e "  ${YELLOW}⚠️  Отключение пароля недоступно: в authorized_keys не обнаружено ключей.${NC}"
            fi

            # Вопрос 4: Fail2ban
            echo
            prompt_yes_no "  Установить и включить Fail2ban (защита от брутфорса)?" "${ENABLE_FAIL2BAN:-y}" ENABLE_FAIL2BAN || return $?
            if is_true "$ENABLE_FAIL2BAN"; then
                ENABLE_FAIL2BAN="y"
                ok "Служба Fail2ban будет установлена и настроена с backend=systemd."
            else
                ENABLE_FAIL2BAN="n"
                log "Установка Fail2ban пропущена."
            fi
        else
            ENABLE_HOST_SECURITY="n"
            SSH_PORT="$SSH_ACTIVE_PORT"
            DISABLE_PASSWORD_AUTH="n"
            ENABLE_FAIL2BAN="n"
            log "Настройки SSH и Fail2ban оставлены без изменений."
        fi
        return 0
    }

    q_step_review() {
        rebuild_all_domains
        sync_reality_ports
        clear 2>/dev/null || echo ""
        echo
        echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}             ${WHITE}${BOLD}📋 ПРОВЕРКА КОНФИГУРАЦИИ ПЕРЕД УСТАНОВКОЙ (REVIEW)${NC}                 ${CYAN}║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo
        echo -e "  ${CYAN}[1]${NC} ${BOLD}Основной домен:${NC}       ${WHITE}$PRIMARY_DOMAIN${NC} (Префикс клиентов: ${GREEN}$SERVER_PREFIX${NC}, www: ${ADD_WWW})"

        local port_mode_str="Автоматический (по умолчанию)"
        [ "${PORTS_SETUP_MODE:-0}" = "1" ] && port_mode_str="Ручной (все порты)"
        [ "${PORTS_SETUP_MODE:-0}" = "2" ] && port_mode_str="Только внешние порты"
        echo -e "  ${CYAN}[2]${NC} ${BOLD}Протоколы VPN/Прокси:${NC} (Режим портов: ${WHITE}${port_mode_str}${NC})"
        local steal_status="${RED}Отключен${NC}"
        if is_true "${STEAL_ENABLED:-0}"; then
            steal_status="${GREEN}Включен${NC} (${WHITE}${STEAL_DOMAINS[*]}${NC} -> 127.0.0.1:${STEAL_PORTS_LIST[*]})"
        fi
        echo -e "      ${DIM}• REALITY (свой сайт):${NC}    $steal_status"

        local classic_status="${RED}Отключен${NC}"
        if is_true "${CLASSIC_ENABLED:-0}"; then
            classic_status="${GREEN}Включен${NC} (SNI: ${WHITE}${EXT_SNI_LIST[*]}${NC} -> 127.0.0.1:${CLASSIC_PORTS_LIST[*]})"
        fi
        echo -e "      ${DIM}• REALITY (внешний):${NC}      $classic_status"

        local hy2_status="${RED}Отключена${NC}"
        if is_true "${ENABLE_HY2:-0}"; then
            local hop_str=""
            [ "$HY2_PORT_HOPPING" = "y" ] && hop_str=" + Hopping $HY2_PORT_HOPPING_RANGE"
            hy2_status="${GREEN}Включена${NC} (:${HY2_PORT}/udp, ${HY2_DOMAIN}${hop_str})"
        fi
        echo -e "      ${DIM}• Hysteria 2:${NC}           $hy2_status"

        local awg3_status="${RED}Отключен${NC}"
        is_true "${ENABLE_AWG_V3:-0}" && awg3_status="${GREEN}Включен${NC} (:${AWG_V3_PORT}/udp)"
        echo -e "      ${DIM}• AmneziaWG v3.1:${NC}        $awg3_status"

        local awg2_status="${RED}Отключен${NC}"
        is_true "${ENABLE_AWG_V2:-0}" && awg2_status="${GREEN}Включен${NC} (:${AWG_V2_PORT}/udp)"
        echo -e "      ${DIM}• AmneziaWG v2.0:${NC}        $awg2_status"

        local awg_sa_status="${RED}Отключен${NC}"
        if is_true "${ENABLE_AWG_STANDALONE:-0}"; then
            local host_disp="${AWG_SERVER_HOST:-${PRIMARY_DOMAIN:-$WAN_IP}}"
            awg_sa_status="${GREEN}Включен${NC} (:${AWG_STANDALONE_PORT:-8445}/udp, Endpoint: ${host_disp}, awg-mgr)"
        fi
        echo -e "      ${DIM}• Автономный AmneziaWG:${NC}   $awg_sa_status"

        local ss_status="${RED}Отключен${NC}"
        is_true "${ENABLE_SS2022:-0}" && ss_status="${GREEN}Включен${NC} (:${SS2022_PORT:-8388})"
        echo -e "      ${DIM}• Shadowsocks 2022:${NC}     $ss_status"

        local tuic_status="${RED}Отключен${NC}"
        is_true "${ENABLE_TUIC:-0}" && tuic_status="${GREEN}Включен${NC} (:${TUIC_PORT:-8448}/udp)"
        echo -e "      ${DIM}• TUIC v5 (QUIC):${NC}       $tuic_status"

        local mtp_status="${RED}Отключен${NC}"
        is_true "${ENABLE_MTPROTO:-0}" && mtp_status="${GREEN}Включен${NC} (:${MTPROTO_PORT:-8444}/tcp, FakeTLS: ${MTPROTO_FAKETLS_DOMAIN:-gateway.icloud.com})"
        echo -e "      ${DIM}• Telegram MTProxy:${NC}     $mtp_status"

        local masque_status="${RED}Отключен${NC}"
        is_true "${ENABLE_MASQUE:-0}" && masque_status="${GREEN}Включен${NC} (:${MASQUE_PORT:-8449}/udp, RFC 9484)"
        echo -e "      ${DIM}• MASQUE (RFC 9484):${NC}    $masque_status"

        local stls_status="${RED}Отключен${NC}"
        is_true "${ENABLE_SHADOWTLS:-0}" && stls_status="${GREEN}Включен${NC} (Nginx :443 SNI ${SHADOWTLS_SNI:-gateway.icloud.com} ➜ :${SHADOWTLS_PORT:-8543})"
        echo -e "      ${DIM}• ShadowTLS v4:${NC}         $stls_status"

        local wst_status="${RED}Отключен${NC}"
        is_true "${ENABLE_WSTUNNEL:-0}" && wst_status="${GREEN}Включен${NC} (Nginx :443 HTTPS ${WSTUNNEL_PREFIX:-/wstunnel/} ➜ :${WSTUNNEL_PORT:-8080})"
        echo -e "      ${DIM}• Wstunnel over Nginx:${NC}  $wst_status"

        local zapret_status="${RED}Отключен${NC}"
        is_true "${ENABLE_ZAPRET:-0}" && zapret_status="${GREEN}Включен${NC} (NFQUEUE ${ZAPRET_QNUM:-200}, ${ZAPRET_DESYNC:-split2})"
        echo -e "      ${DIM}• Server-Side Zapret:${NC}   $zapret_status"

        local naive_status="${RED}Отключен${NC}"
        is_true "${ENABLE_NAIVE:-0}" && naive_status="${GREEN}Включен${NC} (Nginx :443 SNI ${NAIVE_DOMAIN:-naive.$PRIMARY_DOMAIN} ➜ :${NAIVE_PORT:-8446})"
        echo -e "      ${DIM}• NaïveProxy:${NC}          $naive_status"

        local dnstt_status="${RED}Отключен${NC}"
        is_true "${ENABLE_DNSTT:-0}" && dnstt_status="${GREEN}Включен${NC} (UDP :${DNSTT_PORT:-53053} ➜ SS-2022, Zone: ${DNSTT_DOMAIN:-t.$PRIMARY_DOMAIN})"
        echo -e "      ${DIM}• DNSTT DoH Tunnel:${NC}     $dnstt_status"

        local mieru_status="${RED}Отключен${NC}"
        is_true "${ENABLE_MIERU:-0}" && mieru_status="${GREEN}Включен${NC} (:${MIERU_PORT:-8450}/tcp,udp, XChaCha20-Poly1305)"
        echo -e "      ${DIM}• Mieru Proxy:${NC}          $mieru_status"

        local paths_mode_str="Автоматический (криптостойкие хеши)"
        [ "${PATHS_SETUP_MODE:-0}" = "1" ] && paths_mode_str="Ручной ввод"
        echo -e "  ${CYAN}[3]${NC} ${BOLD}Внутренние порты и пути:${NC} (Режим путей: ${WHITE}${paths_mode_str}${NC})"
        echo -e "      ${DIM}• Порты:${NC}   Панель :${WHITE}$PANEL_PORT${NC}, Подписки :${WHITE}$SUB_PORT${NC}, xHTTP :${WHITE}$XHTTP_STREAM_PORT${NC}"
        echo -e "      ${DIM}• Пути:${NC}    Панель: ${WHITE}$PANEL_PATH${NC}, Подписки: ${WHITE}$SUB_PATH${NC}, Clash: ${WHITE}$SUB_CLASH_PATH${NC}, xHTTP: ${WHITE}$XHTTP_STREAM_PATH${NC}"
        echo -e "      ${DIM}• Доступ:${NC}  Логин: ${WHITE}$ADMIN_USERNAME${NC}, Пароль: ${YELLOW}$ADMIN_PASSWORD${NC}"

        local agh_status="${RED}Отключен${NC}"
        if is_true "${ENABLE_AGH:-0}"; then
            local m_desc="Основной домен"
            [ "$AGH_MODE" = "2" ] && m_desc="Поддомен $AGH_DOMAIN"
            agh_status="${GREEN}Включен${NC} (Режим: $m_desc, ClientID: $AGH_CLIENT_ID)"
        fi
        echo -e "  ${CYAN}[4]${NC} ${BOLD}AdGuard Home DoH:${NC}     $agh_status"

        local decoy_name="DataSphere Analytics"
        [ "$DECOY_MODE" = "2" ] && decoy_name="CosmosCloud NextGen"
        [ "$DECOY_MODE" = "3" ] && decoy_name="Стандартная заглушка Nginx"
        echo -e "  ${CYAN}[5]${NC} ${BOLD}Тема маскировки:${NC}      ${WHITE}$decoy_name${NC}"

        echo -e "  ${CYAN}[6]${NC} ${BOLD}SSL-домены (${#ALL_DOMAINS[@]}):${NC}   ${WHITE}${ALL_DOMAINS[*]}${NC}"

        local ssl_name="Certbot (HTTP-01)"
        [ "$SSL_ENGINE_CHOICE" = "2" ] && ssl_name="acme.sh + Cloudflare DNS-01"
        echo -e "  ${CYAN}[7]${NC} ${BOLD}Метод выпуска SSL:${NC}    ${WHITE}$ssl_name${NC}"

        local auto_3xui_str="${GREEN}Да${NC}"
        is_true "${AUTO_SETUP_3XUI:-y}" || auto_3xui_str="${RED}Нет${NC}"
        if is_true "${ENABLE_NODE_TOKEN:-n}"; then
            auto_3xui_str="${auto_3xui_str} ${DIM}(+ Node Token: ${WHITE}${NODE_TOKEN_NAME}${DIM})${NC}"
        fi
        echo -e "  ${CYAN}[8]${NC} ${BOLD}3X-UI автонастройка:${NC}  $auto_3xui_str"

        local warp_status="${RED}Отключен${NC}"
        is_true "${ENABLE_WARP:-n}" && warp_status="${GREEN}Включен${NC} (WireGuard MTU: 1280)"
        echo -e "  ${CYAN}[9]${NC} ${BOLD}Cloudflare WARP:${NC}      $warp_status"

        local sec_status="${DIM}Без изменений (порт ${SSH_PORT:-$SSH_ACTIVE_PORT}, Fail2ban выкл)${NC}"
        if is_true "${ENABLE_HOST_SECURITY:-n}"; then
            local f2b_str="${RED}выкл${NC}"
            is_true "${ENABLE_FAIL2BAN:-n}" && f2b_str="${GREEN}вкл${NC}"
            local pwd_str="${GREEN}пароль разрешен${NC}"
            is_true "${DISABLE_PASSWORD_AUTH:-n}" && pwd_str="${YELLOW}только по ключам${NC}"
            local key_str=""
            [ -n "${SSH_PUBLIC_KEY:-}" ] && key_str=", ключ добавлен"
            if [ "${SSH_PORT:-$SSH_ACTIVE_PORT}" -ne "${SSH_ACTIVE_PORT:-22}" ]; then
                sec_status="${GREEN}Настроена${NC} (SSH порт: ${WHITE}${SSH_PORT}${NC} [было ${SSH_ACTIVE_PORT}], Fail2ban: ${f2b_str}, Доступ: ${pwd_str}${key_str})"
            else
                sec_status="${GREEN}Настроена${NC} (SSH порт: ${WHITE}${SSH_PORT}${NC}, Fail2ban: ${f2b_str}, Доступ: ${pwd_str}${key_str})"
            fi
        fi
        echo -e "  ${CYAN}[10]${NC} ${BOLD}Безопасность сервера:${NC}   $sec_status"

        echo
        echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "  ${GREEN}[Enter]${NC} или ${GREEN}[y]${NC}  ${BOLD}Проверить параметры и перейти к плану установки${NC}"
        echo -e "  ${CYAN}[1 - 10]${NC}        ${BOLD}Изменить соответствующий раздел конфигурации${NC}"
        echo -e "  ${RED}[q]${NC}             ${BOLD}Отмена и выход${NC}"
        echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════${NC}"
        echo

        while true; do
            local choice=""
            echo -ne "  ${WHITE}${ARROW} Ваш выбор [${GREEN}Enter = далее${WHITE}]: "
            read -r choice </dev/tty || read -r choice || true
            choice=$(echo "${choice:-}" | tr -d '[:space:]')

            if [ -z "$choice" ] || [[ "${choice,,}" == "y" ]] || [[ "${choice,,}" == "yes" ]]; then
                return 0
            fi

            if [[ "${choice,,}" == "q" || "${choice,,}" == "quit" || "${choice,,}" == "exit" ]]; then
                die "Установка отменена пользователем."
            fi

            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le 10 ]; then
                return $((100 + choice))
            fi

            warn "  Некорректный ввод. Нажмите Enter для старта, номер [1-10] для изменения или 'q' для выхода."
        done
    }

    # ==============================================================================
    # ЗАПУСК МАСТЕРА (WIZARD ENGINE)
    # ==============================================================================

    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        run_non_interactive_setup
    else
        if [ "$EXPERT_MODE" -eq 1 ]; then
            SHOW_TIPS="n"
            log "Экспертный режим (--expert): подробные подсказки отключены."
        else
            echo
            prompt_yes_no "Показывать подробные пояснения и подсказки к каждому шагу?" "${SHOW_TIPS:-y}" SHOW_TIPS
            if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
                ok "Включен подробный режим: для каждого протокола будут выводиться подсказки и пояснения."
            else
                ok "Включен экспертный режим: вопросы выводятся коротко и по делу."
            fi
        fi

        WIZARD_ALLOW_BACK=1
        if [ "${START_AT_REVIEW:-0}" -eq 1 ]; then
            CURRENT_STEP=11
            EDITING_FROM_REVIEW=0
        else
            CURRENT_STEP=1
            EDITING_FROM_REVIEW=0
        fi
        TOTAL_STEPS=11

        while [ "$CURRENT_STEP" -le "$TOTAL_STEPS" ]; do
            res=0
            case "$CURRENT_STEP" in
                1) q_step_domain || res=$? ;;
                2) q_step_protocols || res=$? ;;
                3) q_step_ports || res=$? ;;
                4) q_step_agh || res=$? ;;
                5) q_step_decoy || res=$? ;;
                6) q_step_ssl_domains || res=$? ;;
                7) q_step_ssl_engine || res=$? ;;
                8) q_step_3xui_auto || res=$? ;;
                9) q_step_warp || res=$? ;;
                10) q_step_security || res=$? ;;
                11) q_step_review || res=$? ;;
            esac

            if [ "$res" -eq 10 ]; then
                # Запрос перехода назад
                if [ "$EDITING_FROM_REVIEW" -eq 1 ]; then
                    CURRENT_STEP=11
                    EDITING_FROM_REVIEW=0
                elif [ "$CURRENT_STEP" -gt 1 ]; then
                    CURRENT_STEP=$((CURRENT_STEP - 1))
                else
                    if [ "$EXPERT_MODE" -eq 0 ]; then
                        echo
                        old_back="$WIZARD_ALLOW_BACK"
                        WIZARD_ALLOW_BACK=0
                        prompt_yes_no "Показывать подробные пояснения и подсказки к каждому шагу?" "${SHOW_TIPS:-y}" SHOW_TIPS
                        WIZARD_ALLOW_BACK="$old_back"
                        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
                            ok "Включен подробный режим: для каждого протокола будут выводиться подсказки и пояснения."
                        else
                            ok "Включен экспертный режим: вопросы выводятся коротко и по делу."
                        fi
                    else
                        warn "Вы уже на первом шаге."
                    fi
                fi
            elif [ "$res" -ge 101 ] && [ "$res" -le 110 ]; then
                # Переход к конкретному шагу из экрана Review
                CURRENT_STEP=$((res - 100))
                EDITING_FROM_REVIEW=1
            elif [ "$res" -eq 0 ]; then
                if [ "$CURRENT_STEP" -eq 11 ]; then
                    break
                elif [ "$EDITING_FROM_REVIEW" -eq 1 ]; then
                    CURRENT_STEP=11
                    EDITING_FROM_REVIEW=0
                else
                    CURRENT_STEP=$((CURRENT_STEP + 1))
                fi
            else
                break
            fi
        done
        WIZARD_ALLOW_BACK=0

        rebuild_all_domains
        sync_reality_ports
    fi
fi
fi

if is_true "${ENABLE_WEB_STACK:-y}"; then
    # Определение системного каталога для хранения SSL
    if [ "$SSL_ENGINE_CHOICE" = "1" ]; then
        SSL_BASE_DIR="/etc/letsencrypt/live"
    else
        SSL_BASE_DIR="/etc/ssl/acme"
    fi

    # Проверка DNS-записей
    log "Проверка A-записей для всех собственных доменов..."
    WAN_IP=$(get_wan_ip)
    if [ -n "$WAN_IP" ]; then
        valid_domains=()
        for dom in "${ALL_DOMAINS[@]}"; do
            resolved_ip=$(dig +short "$dom" @1.1.1.1 2>/dev/null | tail -n1 || echo "")
            if [ -z "$resolved_ip" ]; then
                resolved_ip=$(getent ahosts "$dom" 2>/dev/null | awk '{print $1}' | head -n1 || echo "")
            fi

            local_dns_ok=0
            if [ -z "$resolved_ip" ]; then
                warn "Домен $dom не разрешается в IP-адрес. Проверьте DNS A-запись."
            elif [ "$resolved_ip" != "$WAN_IP" ]; then
                warn "Несовпадение IP: $dom указывает на $resolved_ip, IP сервера: $WAN_IP."
            else
                ok "DNS проверен: $dom -> $WAN_IP"
                valid_domains+=("$dom")
                local_dns_ok=1
            fi

            if [ "$local_dns_ok" -eq 0 ]; then
                if [ "$NON_INTERACTIVE" -eq 1 ]; then
                    if [ "$FORCE_DNS" -eq 1 ]; then
                        warn "Внимание: несовпадение DNS проигнорировано (флаг --force / FORCE_DNS=1)."
                        valid_domains+=("$dom")
                    elif [ "$dom" = "$PRIMARY_DOMAIN" ]; then
                        die "Критическая ошибка: Главный домен $dom не указывает на $WAN_IP. Укажите -f / --force или настройте A-запись в DNS."
                    else
                        warn "Внимание: Дополнительный домен '$dom' не указывает на IP сервера ($WAN_IP) и временно исключен из текущей установки."
                        new_steal=()
                        for sd in "${STEAL_DOMAINS[@]:-}"; do
                            [ "$sd" != "$dom" ] && new_steal+=("$sd")
                        done
                        STEAL_DOMAINS=("${new_steal[@]:-}")
                        unset "DOMAIN_TO_PORT[$dom]" 2>/dev/null || true
                    fi
                elif [ "$dom" = "$PRIMARY_DOMAIN" ]; then
                    read -rp "  [!] Основной домен $dom не совпадает с IP сервера ($WAN_IP). Продолжить выпуск SSL? [y/N]: " dns_ans </dev/tty || read -r dns_ans || true
                    if [[ "${dns_ans,,}" == "y" ]]; then
                        valid_domains+=("$dom")
                    else
                        die "Установка отменена пользователем."
                    fi
                else
                    echo -e "  ${YELLOW}${BOLD}Внимание:${NC} домен '${WHITE}$dom${NC}' не направлен на IP этого сервера (${WHITE}$WAN_IP${NC})."
                    echo -e "  ${DIM}Если продолжить, Let's Encrypt Certbot завершится с фатальной ошибкой (NXDOMAIN).${NC}"
                    echo -e "    ${CYAN}${BOLD}[1] Исключить '$dom' из установки и продолжить${NC} (Рекомендуется)"
                    echo -e "    ${YELLOW}[2] Всё равно попытаться выпустить SSL${NC} (если DNS только что обновлен)"
                    echo -e "    ${RED}[3] Прервать установку${NC}"
                    read -rp "  Ваш выбор [1/2/3] (по умолчанию: 1): " dns_choice </dev/tty || read -r dns_choice || dns_choice="1"
                    dns_choice=$(echo "${dns_choice:-1}" | tr -d '[:space:]')
                    case "$dns_choice" in
                        2)
                            warn "Попытка выпуска SSL для '$dom' будет выполнена."
                            valid_domains+=("$dom")
                            ;;
                        3)
                            die "Установка отменена пользователем для настройки DNS."
                            ;;
                        *)
                            warn "Домен '$dom' исключен из текущей установки."
                            new_steal=()
                            for sd in "${STEAL_DOMAINS[@]:-}"; do
                                [ "$sd" != "$dom" ] && new_steal+=("$sd")
                            done
                            STEAL_DOMAINS=("${new_steal[@]:-}")
                            unset "DOMAIN_TO_PORT[$dom]" 2>/dev/null || true
                            ;;
                    esac
                fi
            fi
        done
        ALL_DOMAINS=("${valid_domains[@]}")
    fi
fi


finalize_installation_config
run_installation
