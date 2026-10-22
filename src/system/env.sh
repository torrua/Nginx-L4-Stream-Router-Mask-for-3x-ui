# =============================================================
#  ФУНКЦИИ НЕИНТЕРАКТИВНОГО РЕЖИМА, CLI И .ENV
# =============================================================
# Примечание: show_help() и generate_config_template() определены выше (до проверки root/OS),
# чтобы --help и --gen-config работали без привилегий суперпользователя.

# @include "common/secrets.sh"
# @include "common/config.sh"
# @include "common/node-token.sh"

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
        local classic_raw="${CLASSIC_SNI:-avito.ru}"
        EXT_SNI_LIST=()
        for cs in ${classic_raw//,/ }; do
            cs=$(echo "$cs" | tr -d '[:space:]')
            if [ -n "$cs" ]; then
                EXT_SNI_LIST+=("$cs")
                EXT_SNI_TO_PORT["$cs"]="${CLASSIC_PORTS_LIST[0]}"
            fi
        done
        [ ${#EXT_SNI_TO_PORT[@]} -gt 0 ] || {
            EXT_SNI_LIST=("avito.ru")
            EXT_SNI_TO_PORT["avito.ru"]="${CLASSIC_PORTS_LIST[0]}"
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

    if [ -z "${DIAG_PATH:-}" ]; then
        local diag_tok
        diag_tok=$(generate_secret_token) || return 1
        DIAG_PATH="/diag-${diag_tok}/"
    fi
    DIAG_PATH="/${DIAG_PATH#/}"
    DIAG_PATH="${DIAG_PATH%/}/"
    if [ -z "${DIAG_TOKEN:-}" ]; then
        DIAG_TOKEN="$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 16 || echo "tok${RANDOM}")"
    fi

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
