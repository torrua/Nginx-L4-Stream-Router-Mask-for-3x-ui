# =============================================================
#  ФУНКЦИИ НЕИНТЕРАКТИВНОГО РЕЖИМА, CLI И .ENV
# =============================================================
# Примечание: show_help() и generate_config_template() определены выше (до проверки root/OS),
# чтобы --help и --gen-config работали без привилегий суперпользователя.

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
        local classic_raw="${CLASSIC_SNI:-gateway.icloud.com}"
        EXT_SNI_LIST=()
        for cs in ${classic_raw//,/ }; do
            cs=$(echo "$cs" | tr -d '[:space:]')
            if [ -n "$cs" ]; then
                EXT_SNI_LIST+=("$cs")
                EXT_SNI_TO_PORT["$cs"]="${CLASSIC_PORTS_LIST[0]}"
            fi
        done
        [ ${#EXT_SNI_TO_PORT[@]} -gt 0 ] || {
            EXT_SNI_LIST=("gateway.icloud.com")
            EXT_SNI_TO_PORT["gateway.icloud.com"]="${CLASSIC_PORTS_LIST[0]}"
        }
    else
        CLASSIC_ENABLED=0
        CLASSIC_PORTS_LIST=()
        EXT_SNI_LIST=()
    fi

    ALL_REALITY_PORTS=()
    for p in "${STEAL_PORTS_LIST[@]:-}"; do [ -n "$p" ] && ALL_REALITY_PORTS+=("$p"); done
    for p in "${CLASSIC_PORTS_LIST[@]:-}"; do [ -n "$p" ] && ALL_REALITY_PORTS+=("$p"); done

    PANEL_PORT="${PANEL_PORT:-10443}"
    RAW_PATH="${PANEL_PATH:-${RAW_PATH:-my-3x-panel}}"
    RAW_PATH="${RAW_PATH#/}"
    RAW_PATH="${RAW_PATH%/}"
    PANEL_PATH="/${RAW_PATH}/"

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
    ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
    DECOY_MODE="${DECOY_MODE:-1}"
    SSL_ENGINE_CHOICE="${SSL_ENGINE_CHOICE:-1}"
    LE_EMAIL="${LE_EMAIL:-}"

    # Нормализация логических переменных (1/0 и y/n)
    local _v
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
    _v="${ENABLE_NODE_TOKEN:-n}"; if is_true "$_v"; then ENABLE_NODE_TOKEN="y"; else ENABLE_NODE_TOKEN="n"; fi
    _v="${AGH_XRAY_DNS:-n}"; if is_true "$_v"; then AGH_XRAY_DNS="y"; else AGH_XRAY_DNS="n"; fi
    HY2_PORT_HOPPING="${HY2_PORT_HOPPING:-n}"
    AUTO_SETUP_3XUI="${AUTO_SETUP_3XUI:-y}"
    PORT_AGH_WEB="${PORT_AGH_WEB:-3000}"
    CF_AUTH_METHOD="${CF_AUTH_METHOD:-1}"
}

load_env_file() {
    local env_file="$1"
    [ -f "$env_file" ] || return 0
    log "Загрузка параметров из конфигурационного файла: $env_file"
    local re_dquote='^"(.*)"$'
    local re_squote="^'(.*)'\$"
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            if [[ "$val" =~ $re_dquote ]] || [[ "$val" =~ $re_squote ]]; then
                val="${BASH_REMATCH[1]}"
            fi
            declare -g "$key=$val"
        fi
    done < "$env_file"
    reconstruct_arrays_from_vars
}

save_session_state() {
    local save_path="${1:-setup_mask.env}"
    # Защита от утечки секретов: ограничиваем права доступа при создании файла
    local old_umask
    old_umask=$(umask)
    umask 077

    local v=""
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
    local auto_setup_3xui_save="n"
    v="${AUTO_SETUP_3XUI:-n}"; is_true "$v" && auto_setup_3xui_save="y"
    local node_token_save="n"
    v="${ENABLE_NODE_TOKEN:-n}"; is_true "$v" && node_token_save="y"
    local warp_save="n"
    v="${ENABLE_WARP:-n}"; is_true "$v" && warp_save="y"
    local agh_save="n"
    v="${ENABLE_AGH:-n}"; is_true "$v" && agh_save="y"
    local agh_xray_save="n"
    v="${AGH_XRAY_DNS:-n}"; is_true "$v" && agh_xray_save="y"

    local _save_panel_path="${RAW_PATH:-${PANEL_PATH:-my-3x-panel}}"
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

    cat << EOF_SAVE > "$save_path"

# ==============================================================================
# АВТОМАТИЧЕСКИ СОХРАНЕННАЯ КОНФИГУРАЦИЯ СЕССИИ
# Для перезапуска без вопросов: ./setup_mask.sh --config $save_path --non-interactive
# ==============================================================================
PRIMARY_DOMAIN="${PRIMARY_DOMAIN:-}"
ADD_WWW="${ADD_WWW:-y}"
EXTRA_SSL_DOMAINS="${EXTRA_SSL_DOMAINS:-}"
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

PANEL_PORT="${PANEL_PORT:-10443}"
PANEL_PATH="${_save_panel_path}"
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
SERVER_PREFIX="${SERVER_PREFIX:-Server}"
SUB_PORT="${SUB_PORT:-55443}"
SUB_PATH="${_save_sub_path}"
SUB_CLASH_PATH="${_save_sub_clash_path}"
SUB_TITLE="${SUB_TITLE:-}"
XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
XHTTP_STREAM_PATH="${_save_xhttp_path}"

ENABLE_HY2="$hy2_save"
HY2_PORT="${HY2_PORT:-443}"
HY2_DOMAIN="${HY2_DOMAIN:-$PRIMARY_DOMAIN}"
HY2_PORT_HOPPING="${HY2_PORT_HOPPING:-y}"
HY2_PORT_HOPPING_RANGE="${HY2_PORT_HOPPING_RANGE:-20000:50000}"

ENABLE_AWG_V3="$awg_v3_save"
AWG_V3_PORT="${AWG_V3_PORT:-8443}"
AWG_HEADER_PROTECTION_KEY="${AWG_HEADER_PROTECTION_KEY:-}"
AWG_RANDOM_TRAILERS="${AWG_RANDOM_TRAILERS:-false}"

ENABLE_AWG_V2="$awg_v2_save"
AWG_V2_PORT="${AWG_V2_PORT:-8444}"

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
AGH_CLIENT_ID="${AGH_CLIENT_ID:-home-router}"
PORT_AGH_WEB="${PORT_AGH_WEB:-3000}"
AGH_XRAY_DNS="$agh_xray_save"
SHOW_TIPS="${SHOW_TIPS:-y}"

TIME_LOCATION="${TIME_LOCATION:-}"
SUB_UPDATES="${SUB_UPDATES:-1}"
SUB_ENCRYPT="${SUB_ENCRYPT:-true}"
BLOCK_SMTP="${BLOCK_SMTP:-true}"
BLOCK_LAN="${BLOCK_LAN:-true}"
WEB_LISTEN="${WEB_LISTEN:-127.0.0.1}"
SUB_LISTEN="${SUB_LISTEN:-127.0.0.1}"
LAST_COMPLETED_STEP="${LAST_COMPLETED_STEP:-0}"
EOF_SAVE
    chmod 600 "$save_path" 2>/dev/null || true
    if [ "$save_path" != "/etc/setup_mask.env" ]; then
        cp -f "$save_path" /etc/setup_mask.env 2>/dev/null || true
        chmod 600 /etc/setup_mask.env 2>/dev/null || true
    fi
    umask "$old_umask"
    ok "Конфигурация текущей сессии сохранена в '$save_path' (chmod 600)."
}
