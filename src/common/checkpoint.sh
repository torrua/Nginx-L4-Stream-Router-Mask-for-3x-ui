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
        *) keys="PRIMARY_DOMAIN ALL_DOMAINS STEAL_PORTS_LIST CLASSIC_PORTS_LIST EXT_SNI_LIST ALL_EXT_SNIS ADD_WWW ENABLE_WEB_STACK ENABLE_STEAL STEAL_DOMAINS STEAL_PORT ENABLE_STEAL_COMPAT STEAL_COMPAT_PORT STEAL_COMPAT_DOMAIN ENABLE_CLASSIC CLASSIC_SNI CLASSIC_PORT REALITY_FINGERPRINT PORTS_SETUP_MODE PATHS_SETUP_MODE CREDS_SETUP_MODE PANEL_PORT PANEL_PATH ADMIN_USERNAME ADMIN_PASSWORD SUB_PORT SUB_PATH SUB_CLASH_PATH SUB_TITLE XHTTP_STREAM_PORT XHTTP_STREAM_PATH ENABLE_HY2 HY2_PORT HY2_DOMAIN HY2_PORT_HOPPING HY2_PORT_HOPPING_RANGE ENABLE_AWG_V3 AWG_V3_PORT ENABLE_AWG_V2 AWG_V2_PORT ENABLE_AWG_STANDALONE AWG_STANDALONE_PORT AWG_SERVER_HOST AWG_PRIMARY_DNS AWG_SECONDARY_DNS ENABLE_AGH AGH_MODE AGH_DOMAIN AGH_USER AGH_PASS AGH_CLIENT_ID AGH_XRAY_DNS PORT_AGH_WEB PORT_AGH_DNS DIAG_PATH DIAG_TOKEN ENABLE_WARP WARP_LICENSE_KEY ENABLE_SS2022 SS2022_PORT SS2022_METHOD SS2022_PASSWORD ENABLE_TUIC TUIC_PORT TUIC_UUID TUIC_PASSWORD ENABLE_MTPROTO MTPROTO_PORT MTPROTO_SECRET ENABLE_MASQUE MASQUE_PORT MASQUE_PASSWORD ENABLE_SHADOWTLS SHADOWTLS_PORT SHADOWTLS_DOMAIN SHADOWTLS_PASSWORD ENABLE_NAIVE NAIVE_PORT NAIVE_DOMAIN NAIVE_USER NAIVE_PASS ENABLE_WSTUNNEL WSTUNNEL_PORT WSTUNNEL_PREFIX WSTUNNEL_SECRET ENABLE_DNSTT DNSTT_PORT DNSTT_DOMAIN DNSTT_PUBKEY ENABLE_ZAPRET ZAPRET_QNUM ZAPRET_DESYNC ZAPRET_FOOLING ENABLE_MIERU MIERU_PORT_MODE MIERU_PORT MIERU_TRANSPORT MIERU_USER MIERU_PASS MIERU_MTU AUTO_SETUP_3XUI ENABLE_NODE_TOKEN NODE_TOKEN NODE_TOKEN_NAME TIME_LOCATION INBOUND_TRAFFIC_RESET INBOUND_TRAFFIC_RESET_DAY BLOCK_SMTP BLOCK_LAN WEB_LISTEN SUB_LISTEN AWG_HEADER_PROTECTION_KEY AWG_RANDOM_TRAILERS AWG_SUBNET_IP AWG_SUBNET_CIDR MTPROTO_FAKETLS_DOMAIN MTPROTO_ADTAG SHADOWTLS_SNI WSTUNNEL_DOMAIN" ;;
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
        packages) command -v curl >/dev/null && command -v openssl >/dev/null ;;
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
