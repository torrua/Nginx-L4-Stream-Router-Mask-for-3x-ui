#!/usr/bin/env bash
# Public installation entrypoint. The execution engine is shared with setup.sh.
#!/usr/bin/env bash
#
# ==============================================================================
# Production AutoSetup: Nginx Stream L4 Router & 3X-UI Companion v9.0.0 Universal
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

SCRIPT_VERSION="v9.0.0"


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
        *) keys="PRIMARY_DOMAIN ALL_DOMAINS STEAL_PORTS_LIST CLASSIC_PORTS_LIST EXT_SNI_LIST ALL_EXT_SNIS ADD_WWW ENABLE_WEB_STACK ENABLE_STEAL STEAL_DOMAINS STEAL_PORT ENABLE_CLASSIC CLASSIC_SNI CLASSIC_PORT PANEL_PORT PANEL_PATH ADMIN_USERNAME ADMIN_PASSWORD SUB_PORT SUB_PATH SUB_CLASH_PATH SUB_TITLE XHTTP_STREAM_PORT XHTTP_STREAM_PATH ENABLE_HY2 HY2_PORT HY2_DOMAIN HY2_PORT_HOPPING HY2_PORT_HOPPING_RANGE ENABLE_AWG_V3 AWG_V3_PORT ENABLE_AWG_V2 AWG_V2_PORT ENABLE_AWG_STANDALONE AWG_STANDALONE_PORT AWG_SERVER_HOST AWG_PRIMARY_DNS AWG_SECONDARY_DNS ENABLE_AGH AGH_MODE AGH_DOMAIN AGH_USER AGH_PASS AGH_CLIENT_ID AGH_XRAY_DNS PORT_AGH_WEB ENABLE_WARP WARP_LICENSE_KEY ENABLE_SS2022 SS2022_PORT SS2022_METHOD SS2022_PASSWORD ENABLE_TUIC TUIC_PORT TUIC_UUID TUIC_PASSWORD ENABLE_MTPROTO MTPROTO_PORT MTPROTO_SECRET ENABLE_MASQUE MASQUE_PORT MASQUE_PASSWORD ENABLE_SHADOWTLS SHADOWTLS_PORT SHADOWTLS_DOMAIN SHADOWTLS_PASSWORD ENABLE_NAIVE NAIVE_PORT NAIVE_DOMAIN NAIVE_USER NAIVE_PASS ENABLE_WSTUNNEL WSTUNNEL_PORT WSTUNNEL_PREFIX WSTUNNEL_SECRET ENABLE_DNSTT DNSTT_PORT DNSTT_DOMAIN DNSTT_PUBKEY ENABLE_ZAPRET ZAPRET_QNUM ZAPRET_DESYNC ZAPRET_FOOLING AUTO_SETUP_3XUI ENABLE_NODE_TOKEN NODE_TOKEN NODE_TOKEN_NAME TIME_LOCATION BLOCK_SMTP BLOCK_LAN WEB_LISTEN SUB_LISTEN AWG_HEADER_PROTECTION_KEY AWG_RANDOM_TRAILERS AWG_SUBNET_IP AWG_SUBNET_CIDR MTPROTO_FAKETLS_DOMAIN MTPROTO_ADTAG SHADOWTLS_SNI WSTUNNEL_DOMAIN" ;;
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
die()  { echo -e "  ${RED}${CROSS:-✖} $*${NC}" >&2; exit 1; }
# Execute in a fresh Bash so a caller's `if`/`||` cannot suppress errexit.
# A private snapshot preserves Bash functions and unexported variables in both modes.
execute_install_task() (
    umask 077
    task_dir=$(mktemp -d "${TMPDIR:-/tmp}/server-task.XXXXXX") || exit 1
    trap 'rm -f -- "$task_dir/task.sh"; rmdir -- "$task_dir"' EXIT
    {
        declare -p | grep -vE '^declare -[^ ]*r|^declare [^ ]+ (BASH[^ =]*|FUNCNAME|DIRSTACK|GROUPS|PIPESTATUS|LINENO|RANDOM|SRANDOM|SECONDS|EPOCHSECONDS|EPOCHREALTIME|_)='
        declare -f
        printf '%s\n' 'shopt -s inherit_errexit 2>/dev/null || true' 'set -Eeuo pipefail' '"$@"'
    } > "$task_dir/task.sh" || exit 1
    bash --noprofile --norc "$task_dir/task.sh" "$@"
)

# Interactive Terminal Spinner & Task Runner
# Supports:
#   - Animated spinner in interactive TTY
#   - Plain output in non-interactive / CI / piped runs
#   - DEBUG_MODE=1 passthrough (full stdout/stderr in real-time)
#   - Required tasks support Retry / Abort; failures cannot be marked as success

run_with_spinner() {
    local task_name="$1"
    shift
    local log_file="${SETUP_MASK_LOG:-${INSTALL_LOG:-${SPINNER_LOG_FILE:-}}}"
    local temporary_log=0
    if [ -z "$log_file" ]; then
        log_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/server-task-log.XXXXXX") || return 1
        temporary_log=1
    fi

    while true; do
        local exit_code=0

        # ── DEBUG MODE: без фона, весь вывод сразу в stdout ──
        if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
            echo -e "\n  ${CYAN}[DEBUG]${NC} ${WHITE}▶ $task_name${NC}"
            echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            execute_install_task "$@" &
            local debug_pid=$!
            if wait "$debug_pid"; then exit_code=0; else exit_code=$?; fi
            if [ $exit_code -eq 0 ]; then
                echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
                echo -e "  ${GREEN}${CHECK:-✔}${NC}  ${WHITE}$task_name${NC} ${GREEN}[ГОТОВО]${NC}\n"
                [ "$temporary_log" -eq 0 ] || rm -f -- "$log_file"
                return 0
            else
                echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            fi
        else
            # ── Нормальный режим: фоновый процесс + спиннер ──
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
            echo -e "  ${DIM}Совет: запустите с флагом ${WHITE}--debug${DIM} для подробного вывода в реальном времени.${NC}\n"
        fi

        # ── Обязательный этап: повторить или прервать ──
        if [ "${NON_INTERACTIVE:-0}" -eq 0 ] && [ -t 1 ]; then
            echo -e "  ${YELLOW}${BOLD}Действия при сбое:${NC}"
            echo -e "    ${CYAN}${BOLD}[1] Повторить попытку (Retry)${NC} — после исправления причин (напр. DNS)"
            echo -e "    ${RED}[3] Прервать установку (Abort)${NC}"
            local retry_ans=""
            read -rp "  Ваш выбор [1/3] (по умолчанию: 1): " retry_ans </dev/tty || read -r retry_ans || retry_ans="1"
            retry_ans=$(echo "${retry_ans:-1}" | tr -d '[:space:]')
            case "$retry_ans" in
                3)
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
  --masque / --no-masque       Включить / отключить MASQUE (RFC 9484 / RFC 9298, :8445/udp)
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
  -f, --force                  Игнорировать ошибки и несовпадения DNS в неинтерактивном режиме
  -v, --version                Показать версию скрипта и выйти
  -h, --help                   Показать справку и выйти

Примеры использования:
  # Интерактивный режим (введенные параметры автоматически сохраняются в server-setup.env):
  ./setup.sh

  # Быстрая экспресс-диагностика всех сервисов и портов:
  ./setup.sh --check

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
# КОНФИГУРАЦИЯ NGINX L4 ROUTER + 3X-UI ДЛЯ SETUP_MASK.SH (v9.0.0 Universal)
# ==============================================================================
# Данный файл позволяет выполнять полностью автоматическую установку:
# ./setup.sh --config server-setup.env --non-interactive --force

# --- 1. ДОМЕНЫ И СЕРТИФИКАТЫ ---
# Основной домен сервера (для панели, подписок, xHTTP и веб-маски) [ОБЯЗАТЕЛЬНО]
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
# Сценарий 1: VLESS REALITY (маскировка под свой сайт с защитой Anti-Loop) [y/n]
ENABLE_STEAL="y"
STEAL_PORT="45443"
# Домены для REALITY (свой сайт, через пробел, например: "cdn.yourdomain.online")
STEAL_DOMAINS="cdn.yourdomain.online"

# Сценарий 2: VLESS REALITY (маскировка под популярные внешние сервисы) [y/n]
ENABLE_CLASSIC="y"
CLASSIC_PORT="46443"
# Внешние доверенные адреса маскировки (через пробел, например: "avito.ru")
CLASSIC_SNI="avito.ru"

# --- 3. ВНУТРЕННИЕ ПОРТЫ И ПУТИ 3X-UI И xHTTP ---
PANEL_PORT="10443"
PANEL_PATH=""
# Учетные данные администратора панели 3X-UI
ADMIN_USERNAME="admin"
ADMIN_PASSWORD=""
# Префикс / название сервера для подключений (например: NL, DE, MyServer)
SERVER_PREFIX="Server"

SUB_PORT="55443"
SUB_PATH=""
# Секретный путь для Clash/Mihomo подписок (по умолчанию: <SUB_PATH>/clash)
SUB_CLASH_PATH=""
SUB_TITLE=""

XHTTP_STREAM_PORT="50443"
XHTTP_STREAM_PATH=""

# --- 4. UDP ТУННЕЛИ (Hysteria 2 / AmneziaWG) ---
# Hysteria 2 (UDP 443) [y/n]
ENABLE_HY2="y"
HY2_PORT="443"
# Отдельный домен для Hysteria 2 (по умолчанию равен PRIMARY_DOMAIN)
HY2_DOMAIN="yourdomain.online"
# Port Hopping: клиент «прыгает» по UDP-портам (обход шейпинга UDP). ВНИМАНИЕ: открывает 20000-50000 в сканерах Censys. По умолчанию: n (стелс) [y/n]
HY2_PORT_HOPPING="n"
# Диапазон UDP-портов для Port Hopping (формат: START:END)
HY2_PORT_HOPPING_RANGE="20000:50000"

# AmneziaWG v3.1 (Transport Protection) [y/n]
ENABLE_AWG_V3="y"
AWG_V3_PORT="8443"
# Защита заголовков Handshake (пусто = автогенерация 32-байтного ключа, 'none' = выкл)
AWG_HEADER_PROTECTION_KEY=""
# Рандомизация хвостов пакетов против анализа длины трафика WireGuard [true/false]
AWG_RANDOM_TRAILERS="false"

# AmneziaWG v2.0 (Для роутеров Keenetic / OpenWrt) [y/n]
ENABLE_AWG_V2="n"
AWG_V2_PORT="8444"

# Настройки сети и DNS для клиентов AmneziaWG:
AWG_PRIMARY_DNS="9.9.9.9"
AWG_SECONDARY_DNS="76.76.2.0"
AWG_SUBNET_IP="10.8.0.0"
AWG_SUBNET_CIDR="22"

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

# Автоматически обновлять ядро Xray-core до последней официальной версии (v26.9.30+) [y/n]
UPDATE_XRAY_CORE="y"

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
# Секретный ClientID для роутера (часть URL DoH)
AGH_CLIENT_ID=""
# Использовать AdGuard Home как DNS для VPN-клиентов (Xray DNS → 127.0.0.1) [y/n]
AGH_XRAY_DNS="n"

# --- 9. ПРОТОКОЛЫ СЛЕДУЮЩЕГО ПОКОЛЕНИЯ (NEXT-GEN) ---
# MASQUE (RFC 9484 / RFC 9298 via Sing-box daemon, HTTP/3 UDP) [y/n]
ENABLE_MASQUE="n"
MASQUE_PORT="8445"
MASQUE_USER="client"
MASQUE_PASSWORD=""

# ShadowTLS v4 + Shadowsocks-2022 (Маскировка под Apple gateway.icloud.com через Nginx Stream L4) [y/n]
ENABLE_SHADOWTLS="n"
SHADOWTLS_PORT="8543"
SHADOWTLS_SNI="gateway.icloud.com"
SHADOWTLS_PASSWORD=""

# Wstunnel over Nginx L7 (Туннелирование WebSocket через порт 443 HTTPS с SSL) [y/n]
ENABLE_WSTUNNEL="n"
WSTUNNEL_PREFIX=""
WSTUNNEL_PORT="8080"
WSTUNNEL_SECRET=""

# Server-Side Zapret nfqws (Десинхронизация DPI ТСПУ через iptables NFQUEUE connbytes 1:6) [y/n]
ENABLE_ZAPRET="n"
ZAPRET_QNUM="200"
ZAPRET_DESYNC="split2"
ZAPRET_FOOLING="md5sig,badseq"

# NaïveProxy (Caddy with forwardproxy@naive via Nginx Stream L4) [y/n]
ENABLE_NAIVE="n"
NAIVE_PORT="8446"
NAIVE_DOMAIN=""
NAIVE_USER="user"
NAIVE_PASS=""

# DNSTT (Emergency DNS Tunneling over DoH via dnstt-server) [y/n]
ENABLE_DNSTT="n"
DNSTT_PORT="53053"
DNSTT_DOMAIN=""
DNSTT_PUBKEY=""

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

# Discover the closest saved configuration without renaming existing user files.
is_true() {
    local val="${1:-0}"
    [[ "$val" == "1" || "${val,,}" == "y" || "${val,,}" == "true" ]]
}

find_config_file() {
    local script_dir="${1:-.}" directory candidate
    for directory in . "$script_dir" /etc /root; do
        for candidate in "$directory/server-setup.env" "$directory/setup_mask.env"; do
            if [ -f "$candidate" ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
    done
    return 1
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

rotate_secret_paths() {
    # Only the full installer may rotate paths; companion scripts preserve them.
    local panel_token ws_token client_token
    panel_token=$(generate_secret_token) || return 1
    ws_token=$(generate_secret_token) || return 1
    client_token=$(generate_secret_token) || return 1
    RAW_PATH="panel-${panel_token}"
    PANEL_PATH="/${RAW_PATH}/"
    WSTUNNEL_PREFIX="/ws-${ws_token}/"
    AGH_CLIENT_ID="client-${client_token}"
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
    ensure_agh_client_id || return 1

    # Сосуществование с Dokploy и протоколы следующего поколения
    _v="${DOKPLOY_COEXISTENCE:-n}"; if is_true "$_v"; then DOKPLOY_COEXISTENCE="y"; else DOKPLOY_COEXISTENCE="n"; fi
    if [ "$DOKPLOY_COEXISTENCE" = "y" ]; then
        ENABLE_WEB_STACK=0
    fi
    _v="${ENABLE_MASQUE:-n}"; if is_true "$_v"; then ENABLE_MASQUE=1; else ENABLE_MASQUE=0; fi
    MASQUE_PORT="${MASQUE_PORT:-8445}"
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
    local re_dquote='^"(.*)"$'
    local re_squote="^'(.*)'\$"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local val="${BASH_REMATCH[2]}"
            if [[ "$val" =~ $re_dquote ]] || [[ "$val" =~ $re_squote ]]; then
                val="${BASH_REMATCH[1]}"
            fi
            declare -g "$key=$val"
            CONFIG_EXPLICIT_KEYS[$key]=1
        fi
    done < "$env_file"
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

PORTS_SETUP_MODE="${PORTS_SETUP_MODE:-1}"
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
MASQUE_PORT="${MASQUE_PORT:-8445}"
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
PORTS_SETUP_MODE="${PORTS_SETUP_MODE:-1}"
SAVED_CONFIG_FILE="server-setup.env"

CLI_PRIMARY_DOMAIN=""
CLI_ADD_WWW=""
CLI_LE_EMAIL=""
CLI_PANEL_PORT=""
CLI_PANEL_PATH=""
CLI_SUB_PATH=""
CLI_SUB_TITLE=""
CLI_XHTTP_STREAM_PATH=""
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
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
ENABLE_MASQUE udp MASQUE_PORT 8445 MASQUE
ENABLE_SHADOWTLS tcp SHADOWTLS_PORT 8543 ShadowTLS
ENABLE_WSTUNNEL tcp WSTUNNEL_PORT 8080 Wstunnel
ENABLE_NAIVE tcp NAIVE_PORT 8446 NaiveProxy
ENABLE_DNSTT udp DNSTT_PORT 53053 DNSTT
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
            printf 'AdGuard-web tcp %s\nAdGuard-DNS tcp 53\nAdGuard-DNS udp 53\n' "${PORT_AGH_WEB:-3000}"
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

    # 2. Проверка системного DNS-порта 53 (TCP/UDP)
    if [[ "${ENABLE_AGH:-0}" == "1" || "${ENABLE_AGH,,}" == "y" ]]; then
        if is_port_in_use "udp" 53 || is_port_in_use "tcp" 53; then
            local dns_owner
            dns_owner=$(get_port_listener_info "udp" 53)
            [ -z "$dns_owner" ] && dns_owner=$(get_port_listener_info "tcp" 53)
            if echo "$dns_owner" | grep -qi "systemd-resolve"; then
                ok "Обнаружен локальный systemd-resolved на порту 53 — будет безопасно отключен стаб-слушатель (DNSStubListener=no) с сохранением системного DNS хоста."
            else
                warn "Порт 53 занят процессом: ${dns_owner:-сторонним DNS-сервером}. AdGuard Home требует свободного порта 53."
            fi
        else
            ok "Порт 53 (DNS) свободен."
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
        local m_port="${MASQUE_PORT:-8445}"
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
    if [ "$protocol" = udp ]; then
        listeners=$(ss -H -lun "sport = :$port" 2>/dev/null) || return 1
    else
        listeners=$(ss -H -ltn "sport = :$port" 2>/dev/null) || return 1
    fi
    [ -n "$listeners" ] || { warn "Port $port/$protocol is not listening"; return 1; }
    ok "Port $port/$protocol: listening"
}

post_install_sanity_check() {
    local all_ok=1 flag protocol variable fallback port
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
            while read -r flag protocol port; do
                [ "$flag" = AWG-standalone ] && continue
                check_required_port "$protocol" "$port" || all_ok=0
            done < <(selected_protocol_ports)
        fi
        if is_true "${ENABLE_AGH:-n}"; then
            check_required_service AdGuardHome || all_ok=0
            check_required_port tcp "${PORT_AGH_WEB:-3000}" || all_ok=0
            check_required_port udp 53 || all_ok=0
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
        if ss -ulpn 2>/dev/null | grep -q ":53 "; then
            echo -e "    • DNS Порт 53:       ${GREEN}СЛУШАЕТ${NC}"
        else
            echo -e "    • DNS Порт 53:       ${YELLOW}не слушает 53${NC}"
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

if [ "$CHECK_MODE" -eq 1 ]; then
    run_doctor_check
    exit 0
fi

if [ "$NON_INTERACTIVE" -eq 1 ]; then
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

has_authorized_keys() {
    local target_user="${1:-root}"
    local user_home
    if [ "$target_user" = "root" ]; then
        user_home="/root"
    else
        user_home=$(eval echo "~$target_user" 2>/dev/null || echo "/home/$target_user")
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
        user_home=$(eval echo "~$target_user" 2>/dev/null || echo "/home/$target_user")
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
        user_home=$(eval echo "~$target_user" 2>/dev/null || echo "/home/$target_user")
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

    # Ищем установленное внешнее соединение на целевой порт
    EST=$(ss -tn sport = ":${TARGET_PORT}" state established 2>/dev/null | grep -vE '127\.0\.0\.1|::1|Local Address' | wc -l)
    if [ "$EST" -gt 0 ]; then
        logger -t ssh-watcher "Обнаружено успешное подключение на порт $TARGET_PORT! Финализация перехода и закрытие порта $ACTIVE_PORT..."

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

    # 2. Формируем список защищаемых портов (и активный, и целевой)
    local port_str="${active_port}"
    if [ "$target_port" -ne "$active_port" ]; then
        port_str="${active_port},${target_port}"
    fi

    mkdir -p /etc/fail2ban
    cat << EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ${port_str}
EOF
    chmod 644 /etc/fail2ban/jail.local 2>/dev/null || true

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

setup_nginx_mainline() {
    export DEBIAN_FRONTEND=noninteractive
    local os_id os_codename
    os_id=$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "ubuntu")
    os_codename=$(lsb_release -cs 2>/dev/null || echo "jammy")

    # 1. Если Nginx уже установлен — проверяем, запускается ли бинарник
    if command -v nginx >/dev/null 2>&1; then
        if nginx -v >/dev/null 2>&1; then
            mkdir -p /etc/nginx/modules-enabled 2>/dev/null || true
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
    curl -s https://get.acme.sh | sh -s email="$acme_mail"
    local _acme_bin="${HOME:-/root}/.acme.sh/acme.sh"
    chmod +x "$_acme_bin"
    "$_acme_bin" --register-account -m "$acme_mail" --server letsencrypt
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

    # Копирование или запись manage_clients.py
    local src_py="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/manage_clients.py"
    if [ -f "$src_py" ]; then
        cp -f "$src_py" "$awg_dir/manage_clients.py"
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

P = 2**255 - 19
def clamp(k_bytes):
    b = bytearray(k_bytes)
    b[0] &= 248; b[31] &= 127; b[31] |= 64
    return int.from_bytes(b, "little")

def x25519(k, u=9):
    x1, x2, z2, x3, z3 = u, 1, 0, u, 1
    for i in range(254, -1, -1):
        bit = (k >> i) & 1
        if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
        A = (x2 + z2) % P; AA = (A * A) % P; B = (x2 - z2) % P; BB = (B * B) % P
        E = (AA - BB) % P; C = (x3 + z3) % P; D = (x3 - z3) % P
        x3 = pow(D * A + C * B, 2, P); z3 = (x1 * pow(D * A - C * B, 2, P)) % P
        x2 = (AA * BB) % P; z2 = (E * (AA + 121665 * E)) % P
        if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
    return (x2 * pow(z2, P - 2, P)) % P

def curve25519_pubkey(priv_b64):
    try:
        raw_priv = base64.b64decode(priv_b64)
        k = clamp(raw_priv)
        pub_raw = x25519(k, 9).to_bytes(32, "little")
        return base64.b64encode(pub_raw).decode()
    except Exception:
        return None

def generate_wg_keypair():
    priv_raw = os.urandom(32)
    k = clamp(priv_raw)
    pub_raw = x25519(k, 9).to_bytes(32, "little")
    return base64.b64encode(priv_raw).decode(), base64.b64encode(pub_raw).decode()

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
    chmod 750 "$awg_dir/manage_clients.py"

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
                srv_priv=$(awg genkey 2>/dev/null || openssl rand -base64 32)
                srv_pub=$(echo "$srv_priv" | awg pubkey 2>/dev/null || true)
            else
                srv_priv=$(openssl rand -base64 32)
                srv_pub=$(python3 -c "
import base64, os
P = 2**255 - 19
def x25519(k, u=9):
    x1, x2, z2, x3, z3 = u, 1, 0, u, 1
    for i in range(254, -1, -1):
        bit = (k >> i) & 1
        if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
        A = (x2 + z2) % P; AA = (A * A) % P; B = (x2 - z2) % P; BB = (B * B) % P
        E = (AA - BB) % P; C = (x3 + z3) % P; D = (x3 - z3) % P
        x3 = pow(D * A + C * B, 2, P); z3 = (x1 * pow(D * A - C * B, 2, P)) % P
        x2 = (AA * BB) % P; z2 = (E * (AA + 121665 * E)) % P
        if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
    return (x2 * pow(z2, P - 2, P)) % P
raw = bytearray(base64.b64decode('$srv_priv'))
raw[0] &= 248; raw[31] &= 127; raw[31] |= 64
k = int.from_bytes(raw, 'little')
pub = x25519(k, 9).to_bytes(32, 'little')
print(base64.b64encode(pub).decode())
" 2>/dev/null || echo "")
            fi
        fi

        local srv_psk=""
        if [ -f "$awg_dir/keys/server_psk.key" ]; then
            srv_psk=$(cat "$awg_dir/keys/server_psk.key" | tr -d '[:space:]')
        else
            srv_psk=$(openssl rand -base64 32)
        fi
        local hpk="${AWG_HEADER_PROTECTION_KEY:-$(openssl rand -base64 32)}"

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
        local z_ver="${ZAPRET_VERSION:-v69.2}"
        local z_tmp="/tmp/zapret_${z_ver}"
        mkdir -p "$z_tmp"
        if curl -fsSL --connect-timeout 15 "https://github.com/bol-van/zapret/releases/download/${z_ver}/zapret-${z_ver}.tar.gz" -o "$z_tmp/zapret.tar.gz" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "https://ghfast.top/https://github.com/bol-van/zapret/releases/download/${z_ver}/zapret-${z_ver}.tar.gz" -o "$z_tmp/zapret.tar.gz" 2>/dev/null; then
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

    if [ ! -x "${bin_dir}/sing-box" ]; then
        local sb_ver="1.11.4"
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

    local masque_p="${MASQUE_PORT:-8445}"
    local masque_u="${MASQUE_USER:-client}"
    local masque_pw="${MASQUE_PASSWORD:-}"
    local cert_file="${SSL_BASE_DIR:-/etc/letsencrypt/live}/${PRIMARY_DOMAIN}/fullchain.pem"
    local key_file="${SSL_BASE_DIR:-/etc/letsencrypt/live}/${PRIMARY_DOMAIN}/privkey.pem"

    mkdir -p /etc/sing-box
    cat << EOF > /etc/sing-box/masque.json
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "masque",
      "tag": "masque-in",
      "listen": "::",
      "listen_port": ${masque_p},
      "tcp_fast_open": true,
      "sniff": true,
      "sniff_override_destination": true,
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
      "connect_udp": {
        "enabled": true,
        "uri_template": "/.well-known/masque/udp/{target_host}/{target_port}/"
      },
      "connect_ip": {
        "enabled": true,
        "uri_template": "/.well-known/masque/ip/"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "port": 25,
        "outbound": "block"
      },
      {
        "ip_is_private": true,
        "outbound": "block"
      }
    ],
    "final": "direct"
  }
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
            ok "Служба Sing-box MASQUE активирована (порт ${masque_p}/udp, H3/QUIC)."
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
        if curl -fsSL --connect-timeout 15 "https://github.com/ihciah/shadow-tls/releases/latest/download/shadow-tls-${st_arch}-unknown-linux-musl" -o "${bin_dir}/shadow-tls" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "https://ghfast.top/https://github.com/ihciah/shadow-tls/releases/latest/download/shadow-tls-${st_arch}-unknown-linux-musl" -o "${bin_dir}/shadow-tls" 2>/dev/null; then
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
    local ws_arch="amd64"
    case "$cur_arch" in
        x86_64|amd64) ws_arch="amd64" ;;
        aarch64|arm64) ws_arch="arm64" ;;
        *) ws_arch="amd64" ;;
    esac

    local bin_dir="${LOCAL_BIN_DIR:-/usr/local/bin}"
    [ -d "$bin_dir" ] || mkdir -p "$bin_dir" 2>/dev/null || true

    if [ ! -x "${bin_dir}/wstunnel" ]; then
        local ws_ver="11.0.0"
        local ws_tmp="/tmp/wstunnel_${ws_ver}"
        mkdir -p "$ws_tmp"
        if curl -fsSL --connect-timeout 15 "https://github.com/erebe/wstunnel/releases/download/v${ws_ver}/wstunnel_${ws_ver}_linux_${ws_arch}.tar.gz" -o "$ws_tmp/ws.tar.gz" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "https://ghfast.top/https://github.com/erebe/wstunnel/releases/download/v${ws_ver}/wstunnel_${ws_ver}_linux_${ws_arch}.tar.gz" -o "$ws_tmp/ws.tar.gz" 2>/dev/null; then
            tar -zxf "$ws_tmp/ws.tar.gz" -C "$ws_tmp" 2>/dev/null || true
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
    if [ ! -x "$caddy_bin" ] && [ -x "${bin_dir}/caddy" ]; then
        caddy_bin="${bin_dir}/caddy"
    fi
    if [ ! -x "$caddy_bin" ] && command -v caddy-naive >/dev/null 2>&1; then
        caddy_bin="$(command -v caddy-naive)"
    fi
    if [ ! -x "$caddy_bin" ] && command -v caddy >/dev/null 2>&1; then
        caddy_bin="$(command -v caddy)"
    fi

    if [ ! -x "$caddy_bin" ]; then
        local caddy_tmp="/tmp/caddy_naive_$$"
        mkdir -p "$caddy_tmp"
        local rel_ver="${SCRIPT_VERSION:-v8.1.0}"
        [[ "$rel_ver" == "v9.0.0" ]] && rel_ver="v8.1.0"
        [[ "$rel_ver" != v* ]] && rel_ver="v${rel_ver}"
        local dl_url="https://github.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/releases/download/${rel_ver}/caddy-naive-linux-${caddy_arch}.tar.gz"
        local dl_mirror="https://ghfast.top/${dl_url}"
        if curl -fsSL --connect-timeout 15 "$dl_url" -o "$caddy_tmp/caddy.tar.gz" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "$dl_mirror" -o "$caddy_tmp/caddy.tar.gz" 2>/dev/null; then
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
        naive_pass=$(python3 -c "import secrets; print(secrets.token_urlsafe(16))" 2>/dev/null || openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' || echo "ChangeMeNaive2026")
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
            ok "Служба NaïveProxy активирована (порт ${naive_port}, user: ${naive_user})."
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
        local rel_ver="${SCRIPT_VERSION:-v8.1.0}"
        [[ "$rel_ver" == "v9.0.0" ]] && rel_ver="v8.1.0"
        [[ "$rel_ver" != v* ]] && rel_ver="v${rel_ver}"
        local dl_url="https://github.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/releases/download/${rel_ver}/dnstt-server-linux-${dnstt_arch}.tar.gz"
        local dl_mirror="https://ghfast.top/${dl_url}"
        if curl -fsSL --connect-timeout 15 "$dl_url" -o "$dnstt_tmp/dnstt.tar.gz" 2>/dev/null || \
           curl -fsSL --connect-timeout 15 "$dl_mirror" -o "$dnstt_tmp/dnstt.tar.gz" 2>/dev/null; then
            tar -zxf "$dnstt_tmp/dnstt.tar.gz" -C "$dnstt_tmp" 2>/dev/null || true
            if [ -f "$dnstt_tmp/dnstt-server" ]; then
                cp "$dnstt_tmp/dnstt-server" "${bin_dir}/dnstt-server"
                chmod +x "${bin_dir}/dnstt-server"
                dnstt_bin="${bin_dir}/dnstt-server"
            fi
        fi
        rm -rf "$dnstt_tmp" 2>/dev/null || true
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
            python3 -c "
import os
P = 2**255 - 19
A24 = 121665
def clamp(k_bytes):
    b = bytearray(k_bytes)
    b[0] &= 248
    b[31] &= 127
    b[31] |= 64
    return int.from_bytes(b, 'little')
def x25519(k, u=9):
    x1, x2, z2, x3, z3 = u, 1, 0, u, 1
    for i in range(254, -1, -1):
        bit = (k >> i) & 1
        if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
        A = (x2 + z2) % P; AA = (A * A) % P; B = (x2 - z2) % P; BB = (B * B) % P; E = (AA - BB) % P
        C = (x3 + z3) % P; D = (x3 - z3) % P; DA = (D * A) % P; CB = (C * B) % P
        x3 = pow(DA + CB, 2, P); z3 = (x1 * pow(DA - CB, 2, P)) % P; x2 = (AA * BB) % P; z2 = (E * (AA + A24 * E)) % P
        if bit: x2, x3 = x3, x2; z2, z3 = z3, z2
    return (x2 * pow(z2, P - 2, P)) % P
raw_priv = os.urandom(32)
k = clamp(raw_priv)
pub = ((x25519(k, 9)) % P).to_bytes(32, 'little').hex()
with open('/etc/dnstt/server.key', 'w') as kf:
    kf.write(raw_priv.hex() + '\n')
with open('/etc/dnstt/server.pub', 'w') as pf:
    pf.write(pub + '\n')
" 2>/dev/null || {
                head /dev/urandom 2>/dev/null | tr -dc 0-9a-f | head -c 64 > /etc/dnstt/server.key 2>/dev/null || echo "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" > /etc/dnstt/server.key
                head /dev/urandom 2>/dev/null | tr -dc 0-9a-f | head -c 64 > /etc/dnstt/server.pub 2>/dev/null || echo "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210" > /etc/dnstt/server.pub
            }
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
            ok "Служба DNSTT активирована (порт ${dnstt_port}/udp, домен: ${dnstt_domain})."
        else
            warn "Бинарник ${dnstt_bin} не найден, запуск dnstt-server отложен."
        fi
    fi
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
    express_default CLASSIC_SNI avito.ru
    express_default ENABLE_HY2 y
    express_default HY2_PORT 443
    express_default HY2_DOMAIN "$PRIMARY_DOMAIN"
    express_default ENABLE_AWG_V3 y
    express_default AWG_V3_PORT 8443
    express_default ENABLE_AWG_V2 n
    express_default DECOY_MODE 1
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
ENABLE_MASQUE udp MASQUE_PORT 8445 MASQUE
ENABLE_SHADOWTLS tcp SHADOWTLS_PORT 8543 ShadowTLS
ENABLE_WSTUNNEL tcp WSTUNNEL_PORT 8080 Wstunnel
ENABLE_NAIVE tcp NAIVE_PORT 8446 NaiveProxy
ENABLE_DNSTT udp DNSTT_PORT 53053 DNSTT
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
            printf 'AdGuard-web tcp %s\nAdGuard-DNS tcp 53\nAdGuard-DNS udp 53\n' "${PORT_AGH_WEB:-3000}"
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
        [[ "$value" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$value))" -ge 1 ] && [ "$((10#$value))" -le 65535 ] || die "Некорректный порт $name: $value"
        binding="$transport:$((10#$value))"
        [ -z "${claimed[$binding]:-}" ] || die "Конфликт порта $value/$transport: ${claimed[$binding]} и $name. Измените порт одного из компонентов."
        claimed[$binding]="$name"
    done < <(installation_listeners)
}

run_installation() {
    validate_installation_config
    inspect_port_conflicts
    build_installation_plan
    confirm_installation_plan
    save_session_state "${SAVED_CONFIG_FILE:-server-setup.env}"
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
        command -v ufw >/dev/null 2>&1 && ufw allow 80/tcp >/dev/null 2>&1 || true
        command -v ufw >/dev/null 2>&1 && ufw allow 443/tcp >/dev/null 2>&1 || true
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
    modules_load_block=""
    if compgen -G "/etc/nginx/modules-enabled/*.conf" >/dev/null 2>&1; then
        modules_load_block="include /etc/nginx/modules-enabled/*.conf;"
    fi

    # Определение поддержки директив HTTP/2 в установленной версии Nginx
    determine_nginx_http2_mode

    wstunnel_badbot_bypass=""
    if is_true "${ENABLE_WSTUNNEL:-0}" && [ -n "${WSTUNNEL_PREFIX:-}" ]; then
        wstunnel_clean_prefix="${WSTUNNEL_PREFIX%/}"
        wstunnel_badbot_bypass="        ~^1:[01]:${wstunnel_clean_prefix}/ 0;"$'\n'
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
if [[ "${ENABLE_AGH:-0}" == "1" || "${ENABLE_AGH,,}" == "y" ]] && [ "${AGH_MODE:-1}" = "1" ]; then
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
    wstunnel_clean_prefix="${WSTUNNEL_PREFIX%/}"
    WSTUNNEL_LOCATION_BLOCK="
    # --- ЛОКАЦИЯ: WSTUNNEL (L7 WebSocket Tunnel) ---
    location ^~ ${wstunnel_clean_prefix}/ {
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
    listen unix:/dev/shm/nginx-http.sock ssl default_server proxy_protocol;
    listen 127.0.0.1:$REALITY_FALLBACK_PORT ssl default_server proxy_protocol;
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
    if [[ "${ENABLE_AGH:-0}" == "1" || "${ENABLE_AGH,,}" == "y" ]] && [ "${AGH_MODE:-1}" = "2" ] && [ -n "${AGH_DOMAIN:-}" ] && [ -f "${SSL_BASE_DIR}/$AGH_DOMAIN/fullchain.pem" ]; then
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

    run_with_spinner "Тестирование конфигурации и перезапуск Nginx Mainline" nginx_reload_task || {
        restore_nginx_configs
        die "Ошибка запуска Nginx. Конфигурация автоматически возвращена в исходное состояние."
    }
}
install_step_firewall() {
    :
# Apply only the ports owned by this installation, preserving existing rules.
command -v ufw >/dev/null 2>&1 || die "UFW is not installed."
ufw allow "${SSH_ACTIVE_PORT:-22}/tcp"
ufw allow "${SSH_PORT:-${SSH_ACTIVE_PORT:-22}}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
for private_port in "${PANEL_PORT:-10443}" "${SUB_PORT:-55443}" "${XHTTP_STREAM_PORT:-50443}" "${REALITY_FALLBACK_PORT:-9443}" "${ALL_REALITY_PORTS[@]:-}"; do
    [ -z "$private_port" ] && continue
    ufw deny "$private_port/tcp"
done
while read -r protocol transport port; do
    if protocol_is_public "$protocol"; then
        ufw allow "$port/$transport"
    else
        ufw deny "$port/$transport"
    fi
done < <(selected_protocol_ports)
if is_true "${ENABLE_HY2:-n}" && is_true "${HY2_PORT_HOPPING:-n}" && [ -n "${HY2_PORT_HOPPING_RANGE:-}" ]; then
    ufw allow "${HY2_PORT_HOPPING_RANGE}/udp"
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
        if grep -q '^\*nat' /etc/ufw/before.rules 2>/dev/null; then
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
        if grep -q '^\*nat' /etc/ufw/before6.rules 2>/dev/null; then
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

    # 2. Использование локальной версии configure-panel.sh с сетевым fallback
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "/root")"
    CONFIG_EXEC="$script_dir/configure-panel.sh"
    if [ ! -f "$CONFIG_EXEC" ]; then
        raw_url="https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/configure-panel.sh?v=$(date +%s)"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$raw_url" -o /tmp/configure-panel.sh 2>/dev/null && chmod +x /tmp/configure-panel.sh 2>/dev/null || true
        elif command -v wget >/dev/null 2>&1; then
            wget -qO /tmp/configure-panel.sh "$raw_url" 2>/dev/null && chmod +x /tmp/configure-panel.sh 2>/dev/null || true
        fi
        CONFIG_EXEC="/tmp/configure-panel.sh"
    else
        chmod +x "$CONFIG_EXEC" 2>/dev/null || true
    fi

    # Развертывание фоновых служб нового поколения (Zapret, MASQUE, ShadowTLS, Wstunnel, NaïveProxy, DNSTT)
    # Выполняется ДО configure-panel.sh, чтобы сгенерированные ключи и пароли попали в сводный отчет клиента
    if command -v deploy_native_nextgen_services >/dev/null 2>&1; then
        deploy_native_nextgen_services
        save_session_state "$SAVED_CONFIG_FILE"
    fi

    if [ -f "$CONFIG_EXEC" ]; then
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
            bash "$CONFIG_EXEC" --config "$SAVED_CONFIG_FILE" -y
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
        # 1. Отключение systemd-resolved StubListener
        mkdir -p /etc/systemd/resolved.conf.d
        cat << 'EOF_RESOLVED' > /etc/systemd/resolved.conf.d/adguard.conf
[Resolve]
DNS=1.1.1.1 8.8.8.8
DNSStubListener=no
EOF_RESOLVED
        systemctl restart systemd-resolved 2>/dev/null || true
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true

        # 2. Скачивание и распаковка AdGuard Home (если ещё не установлен)
        if [ ! -f /opt/AdGuardHome/AdGuardHome ]; then
            agh_arch="amd64"
            cur_arch=$(uname -m 2>/dev/null || echo "x86_64")
            case "$cur_arch" in
                x86_64) agh_arch="amd64" ;;
                aarch64|arm64) agh_arch="arm64" ;;
                armv7l|armhf) agh_arch="armv7" ;;
                *) agh_arch="amd64" ;;
            esac

            curl -fsSL "https://static.adguard.com/adguardhome/release/AdGuardHome_linux_${agh_arch}.tar.gz" -o /tmp/agh.tar.gz 2>/dev/null || \
                curl -fsSL "https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${agh_arch}.tar.gz" -o /tmp/agh.tar.gz
            tar -zxf /tmp/agh.tar.gz -C /opt/ >/dev/null 2>&1
            rm -f /tmp/agh.tar.gz
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
  port: 53
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
import sqlite3, json

db_path = '$xui_db'
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute(\"SELECT value FROM settings WHERE key='xrayTemplateConfig'\")
row = cur.fetchone()
if row and row[0]:
    try:
        cfg = json.loads(row[0])
        dns = cfg.get('dns', {})
        dns['servers'] = ['127.0.0.1']
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
      * ${YELLOW}Вкладка «Безопасность»:${NC} ${GREEN}Reality${NC} | uTLS: ${GREEN}chrome / firefox${NC}
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
      * ${YELLOW}Вкладка «Безопасность»:${NC} ${GREEN}Reality${NC} | uTLS: ${GREEN}chrome / firefox${NC}
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
else
    # В неинтерактивном режиме с переданным конфигом пропускаем интервью и возобновляем
    SKIP_INTERVIEW=1
    if [ -n "${CHECKPOINT_FAILED:-}" ] && [ "${FAILED_STEP_NUM:-0}" -gt 0 ]; then
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
                    PORTS_SETUP_MODE=1
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

        if [ "$START_AT_REVIEW" -eq 0 ]; then
            echo
            echo -e "  ${WHITE}${BOLD}Шаг 0: Выбор компонентов для установки:${NC}\n"
            echo -e "  ${CYAN}${BOLD}[1] Комплекс веб-маскировки Nginx + панель 3X-UI${NC}"
            echo -e "      ${DIM}• VLESS REALITY, VLESS xHTTP, Trojan, Hysteria 2, инбаунды 3X-UI${NC}"
            echo -e "      ${DIM}• Автоматический выпуск SSL (Let's Encrypt / Cloudflare), веб-маскировка${NC}"
            prompt_yes_no "  Установить комплекс веб-маскировки Nginx + 3X-UI?" "${ENABLE_WEB_STACK:-y}" ENABLE_WEB_STACK
            echo
            echo -e "  ${CYAN}${BOLD}[2] Автономный сервер AmneziaWG (awg-mgr)${NC}"
            echo -e "      ${DIM}• Работает как системная служба ядра Linux (awg-quick@awg0)${NC}"
            echo -e "      ${DIM}• Управление клиентами через CLI: awg-mgr add/list/qr/remove${NC}"
            echo -e "      ${DIM}• Защита от блокировок по протоколу AmneziaWG (Junk packets, S1-S4, H1-H4)${NC}"
            prompt_yes_no "  Установить автономный сервер AmneziaWG (awg-mgr)?" "${ENABLE_AWG_STANDALONE:-y}" ENABLE_AWG_STANDALONE

            while ! is_true "${ENABLE_WEB_STACK:-y}" && ! is_true "${ENABLE_AWG_STANDALONE:-y}"; do
                echo
                warn "Не выбран ни один компонент для установки! Выберите хотя бы один сервис."
                prompt_yes_no "  Установить комплекс веб-маскировки Nginx + 3X-UI?" "y" ENABLE_WEB_STACK
                prompt_yes_no "  Установить автономный сервер AmneziaWG (awg-mgr)?" "y" ENABLE_AWG_STANDALONE
            done
        fi



        if ! is_true "${ENABLE_WEB_STACK:-y}"; then
            # Сценарий только автономного сервера AmneziaWG
            EXPRESS_MODE=0
            EXPERT_MODE=0
            run_standalone_awg_wizard
            SKIP_WIZARD_STEPS=1
        fi

        if [ "${SKIP_WIZARD_STEPS:-0}" -eq 0 ] && [ -z "${PRIMARY_DOMAIN:-}" ] && [ "$EXPRESS_MODE" -eq 0 ] && [ "$EXPERT_MODE" -eq 0 ]; then
            echo -e "  ${WHITE}${BOLD}Выберите режим настройки:${NC}\n"
            echo -e "    ${CYAN}${BOLD}[1] Экспресс-установка (Рекомендуется)${NC} — Настройка в 2 вопроса"
            echo -e "        ${DIM}• Ввод только домена и email для Let's Encrypt.${NC}"
            echo -e "        ${DIM}• Автоматический выбор лучших протоколов (VLESS REALITY, VLESS xHTTP, AmneziaWG).${NC}"
            echo -e "        ${DIM}• Готовый сайт-маскировка DataSphere Analytics + автогенерация безопасных путей.${NC}\n"
            echo -e "    ${YELLOW}${BOLD}[2] Экспертная детальная настройка${NC} — Полный контроль параметров"
            echo -e "        ${DIM}• Пошаговый выбор всех портов, путей подписок, Hysteria 2 и AmneziaWG.${NC}\n"

            while true; do
                echo -ne "  ${WHITE}${ARROW} Ваш выбор [1/2] (по умолчанию: 1): ${NC}"
                read -r MODE_INPUT </dev/tty || read -r MODE_INPUT || MODE_INPUT="1"
                MODE_INPUT=$(echo "${MODE_INPUT:-1}" | tr -d '[:space:]')
                if [ "$MODE_INPUT" = "1" ]; then
                    EXPRESS_MODE=1
                    break
                elif [ "$MODE_INPUT" = "2" ]; then
                    EXPRESS_MODE=0
                    EXPERT_MODE=1
                    break
                fi
                echo -e "  ${RED}Пожалуйста, введите 1 или 2.${NC}"
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
    'avito.ru',
    'www.avito.ru',
    'dl.google.com',
    'www.apple.com',
    'itunes.apple.com',
    'www.samsung.com',
    'www.nvidia.com',
    'www.microsoft.com',
    'www.amazon.com',
    'www.amd.com',
    'www.sony.com',
    'cdn.discordapp.com',
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
            local classic_sni_list="${CLASSIC_SNI:-avito.ru}"
            EXT_SNI_LIST=()
            for ext_sni in $classic_sni_list; do
                [[ "$ext_sni" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || continue
                EXT_SNI_TO_PORT["$ext_sni"]="$c_port"
                EXT_SNI_LIST+=("$ext_sni")
                ALL_EXT_SNIS+=("$ext_sni")
                ok "    Внешний SNI $ext_sni привязан к инбаунд-порту $c_port"
            done
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
            MASQUE_PORT="${MASQUE_PORT:-8445}"
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
        echo -e "${YELLOW}━━━ Шаг 1/13: Конфигурация главного сайта (домена) ━━━${NC}"
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

    q_step_steal() {
        echo
        echo -e "${YELLOW}━━━ Шаг 2/13: Настройка VLESS REALITY (маскировка под свой сайт) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Режим REALITY, маскирующийся под ${BOLD}собственный поддомен${NC} (напр. cdn.$PRIMARY_DOMAIN)."
            echo -e "     ${GREEN}Преимущество:${NC} Трафик выглядит как обычный просмотр вашего сайта."
            echo -e "     Защищает от блокировок сторонних адресов маскировки со стороны систем фильтрации."
            echo
        fi

        prompt_yes_no "Включить VLESS REALITY (маскировка под свой сайт)?" "${ENABLE_STEAL:-y}" ENABLE_STEAL || return $?

        if is_true "${ENABLE_STEAL:-y}"; then
            STEAL_ENABLED=1
            local old_steal_dom="${STEAL_DOMAINS[0]:-${STEAL_DOMAINS_STR:-cdn.$PRIMARY_DOMAIN}}"
            local old_steal_port="${STEAL_PORTS_LIST[0]:-${STEAL_PORT:-45443}}"
            STEAL_PORTS_LIST=()
            STEAL_DOMAINS=()

            local port_input=""
            prompt_default "  Локальный порт Xray для REALITY (свой сайт)" "$old_steal_port" port_input || return $?
            STEAL_PORT="$port_input"
            if [[ ! "$STEAL_PORT" =~ ^[0-9]+$ ]] || [ "$STEAL_PORT" -le 0 ] || [ "$STEAL_PORT" -gt 65535 ]; then
                warn "  Некорректный номер порта. Установлен порт по умолчанию: 45443."
                STEAL_PORT="45443"
            fi
            STEAL_PORTS_LIST+=("$STEAL_PORT")

            local s_dom_in=""
            prompt_default "  Домен/поддомен для маскировки REALITY на порту $STEAL_PORT" "$old_steal_dom" s_dom_in || return $?
            s_dom_in=$(echo "${s_dom_in:-$old_steal_dom}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

            if [[ ! "$s_dom_in" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                warn "  Некорректный синтаксис домена '$s_dom_in'. Использован $old_steal_dom."
                s_dom_in="$old_steal_dom"
            fi

            if [ "$s_dom_in" = "$PRIMARY_DOMAIN" ]; then
                warn "  Коллизия: '$s_dom_in' совпадает с главным доменом (PRIMARY_DOMAIN)!"
                warn "  Главный домен зарезервирован за Nginx L7 (панель, веб-маска, подписки, xHTTP)."
                warn "  Для REALITY со своим сайтом укажите поддомен (например, cdn.$PRIMARY_DOMAIN)."
                s_dom_in="$old_steal_dom"
            fi

            STEAL_DOMAINS=("$s_dom_in")
            DOMAIN_TO_PORT["$s_dom_in"]="$STEAL_PORT"
            ok "  Домен $s_dom_in привязан к инбаунд-порту $STEAL_PORT"

            echo ""
            [ "${SHOW_TIPS:-y}" = "y" ] && echo -e "  ${CYAN}[i]${NC} ${DIM}Одного подключения REALITY (свой сайт) достаточно для всех ваших устройств.${NC}"
            local add_more=""
            prompt_yes_no "  Создать еще одно изолированное подключение (на другом порту)?" "n" add_more || return $?
            if [[ "${add_more,,}" == "y" ]]; then
                local extra_port="" extra_dom=""
                prompt_default "    Второй порт REALITY (свой сайт)" "45444" extra_port || return $?
                prompt_default "    Второй поддомен (напр. xr.$PRIMARY_DOMAIN)" "xr.$PRIMARY_DOMAIN" extra_dom || return $?
                extra_dom=$(echo "${extra_dom:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
                if [[ "$extra_dom" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                    STEAL_PORTS_LIST+=("$extra_port")
                    STEAL_DOMAINS+=("$extra_dom")
                    DOMAIN_TO_PORT["$extra_dom"]="$extra_port"
                    ok "    Второй домен $extra_dom привязан к порту $extra_port"
                fi
            fi
        else
            STEAL_ENABLED=0
            STEAL_PORTS_LIST=()
            STEAL_DOMAINS=()
            log "Сценарий VLESS REALITY (свой сайт) отключен."
        fi

        rebuild_all_domains
        sync_reality_ports
        return 0
    }

    q_step_classic() {
        echo
        echo -e "${YELLOW}━━━ Шаг 3/13: Настройка VLESS REALITY (маскировка под популярные сервисы) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Режим REALITY, маскирующийся под ${BOLD}известные сервисы${NC} (Apple, Microsoft, Samsung)."
            echo -e "     ${GREEN}Преимущество:${NC} Даже если ваш собственный домен окажется недоступен, это подключение продолжит"
            echo -e "     работать, используя валидные TLS 1.3 сертификаты внешних ресурсов."
            echo
        fi

        prompt_yes_no "Включить VLESS REALITY (маскировка под популярные сервисы)?" "${ENABLE_CLASSIC:-y}" ENABLE_CLASSIC || return $?

        if [[ "${ENABLE_CLASSIC,,}" == "y" || "${ENABLE_CLASSIC:-}" == "1" ]]; then
            CLASSIC_ENABLED=1
            CLASSIC_PORTS_LIST=()
            EXT_SNI_LIST=()

            local port_input=""
            prompt_default "  Локальный порт Xray для REALITY (внешние сервисы)" "${CLASSIC_PORT:-46443}" port_input || return $?
            CLASSIC_PORT="$port_input"
            if [[ ! "$CLASSIC_PORT" =~ ^[0-9]+$ ]] || [ "$CLASSIC_PORT" -le 0 ] || [ "$CLASSIC_PORT" -gt 65535 ]; then
                warn "  Некорректный номер порта. Установлен порт по умолчанию: 46443."
                CLASSIC_PORT="46443"
            fi
            CLASSIC_PORTS_LIST+=("$CLASSIC_PORT")

            local scanned_snis=()
            local scanned_lats=()
            if command -v python3 >/dev/null 2>&1; then
                echo -e "  ${CYAN}[*] Сканирование лучших REALITY-доменов по задержке (TLS 1.3 + h2)...${NC}"
                while read -r s_host s_lat; do
                    [ -n "$s_host" ] || continue
                    scanned_snis+=("$s_host")
                    scanned_lats+=("$s_lat")
                done < <(scan_reality_candidates)
            fi

            if [ "${#scanned_snis[@]}" -eq 0 ]; then
                scanned_snis=("avito.ru" "www.avito.ru" "dl.google.com" "www.apple.com" "www.samsung.com" "www.nvidia.com" "www.microsoft.com")
                scanned_lats=("fast" "fast" "fast" "fast" "fast" "fast" "fast")
            fi

            local default_classic_sni="${CLASSIC_SNI:-${scanned_snis[0]}}"

            echo ""
            echo -e "  ${BOLD}Доступные проверенные кандидаты маскировки (REALITY Targets):${NC}"
            for idx in "${!scanned_snis[@]}"; do
                local num=$((idx + 1))
                local h="${scanned_snis[$idx]}"
                local lat="${scanned_lats[$idx]}"
                local marker="  "
                [ "$h" = "$default_classic_sni" ] && marker="${GREEN}★ ${NC}"
                local lat_str="${DIM}(${lat} ms)${NC}"
                [ "$lat" = "fast" ] && lat_str=""
                echo -e "    ${CYAN}[$num]${NC} $marker${WHITE}$h${NC} $lat_str"
            done
            echo -e "    ${CYAN}[C]${NC}   ${DIM}Ввести свой собственный домен вручную${NC}"
            echo ""

            while true; do
                echo -ne "  ${WHITE}${ARROW} Выберите номер [1-${#scanned_snis[@]}], домен или Enter для [${GREEN}${default_classic_sni}${WHITE}] ${DIM}(b - назад)${NC}: "
                local ext_input=""
                read -r ext_input </dev/tty || read -r ext_input || true
                ext_input=$(echo "${ext_input:-}" | tr -d '[:space:]')
                if [[ "${ext_input,,}" == "b" || "${ext_input,,}" == "back" || "${ext_input,,}" == "назад" ]]; then
                    return 10
                fi

                local ext_sni=""
                if [ -z "$ext_input" ]; then
                    ext_sni="$default_classic_sni"
                elif [[ "$ext_input" =~ ^[0-9]+$ ]] && [ "$ext_input" -ge 1 ] && [ "$ext_input" -le "${#scanned_snis[@]}" ]; then
                    ext_sni="${scanned_snis[$((ext_input - 1))]}"
                elif [[ "${ext_input,,}" == "c" ]]; then
                    prompt_default "    Введите свой домен SNI (например, dl.google.com)" "dl.google.com" ext_sni || return $?
                    ext_sni=$(echo "${ext_sni:-}" | tr -d '[:space:]')
                else
                    ext_sni="$ext_input"
                fi

                if [[ ! "$ext_sni" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                    warn "    Некорректный формат SNI: '$ext_sni'. Попробуйте снова."
                    continue
                fi

                CLASSIC_SNI="$ext_sni"
                EXT_SNI_LIST=("$ext_sni")
                EXT_SNI_TO_PORT["$ext_sni"]="$CLASSIC_PORT"
                ALL_EXT_SNIS=("$ext_sni")
                ok "  Внешний SNI $ext_sni привязан к порту $CLASSIC_PORT"
                break
            done
        else
            CLASSIC_ENABLED=0
            CLASSIC_PORTS_LIST=()
            EXT_SNI_LIST=()
            ALL_EXT_SNIS=()
            log "Сценарий VLESS REALITY (внешние сервисы) отключен."
        fi

        sync_reality_ports
        return 0
    }

    q_step_ports() {
        echo
        echo -e "${YELLOW}━━━ Шаг 4/13: Настройка путей и внутренних портов (3X-UI и VLESS xHTTP) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Внутренние порты и секретные URI-пути для веб-панели 3X-UI,"
            echo -e "     сервера подписок для клиентов и инбаунда VLESS xHTTP (HTTP/2 Stream-One)."
            echo
            echo -e "  ${BOLD}Выберите вариант настройки:${NC}"
            echo -e "    ${GREEN}[1] Рекомендованные безопасные настройки (Enter / Быстро)${NC}"
            echo -e "        ${DIM}• Порты: Панель :10443, Подписки :55443, xHTTP :50443${NC}"
            echo -e "        ${DIM}• Пути: Случайные криптостойкие URI (защита от сетевых сканеров и ботов)${NC}"
            echo -e "        ${DIM}• Логин: admin, Пароль: случайный стойкий хэш${NC}"
            echo -e "    ${CYAN}[2] Ручная экспертная настройка (задать все порты, логин, пароль и пути вручную)${NC}"
            echo
        else
            echo -e "  ${BOLD}Вариант настройки:${NC} [1] Рекомендованные порты/пути (Enter)  [2] Ручная экспертная настройка"
        fi

        prompt_default "  Ваш выбор (1 или 2)" "${PORTS_SETUP_MODE:-1}" PORTS_SETUP_MODE || return $?

        if [ "$PORTS_SETUP_MODE" = "2" ]; then
            prompt_default "  Внутренний порт панели 3X-UI" "${PANEL_PORT:-10443}" PANEL_PORT || return $?
            prompt_default "  Логин администратора 3X-UI" "${ADMIN_USERNAME:-admin}" ADMIN_USERNAME || return $?
            local def_pass="${ADMIN_PASSWORD:-$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 12 || echo "Admin1234567")}"
            prompt_default "  Пароль администратора 3X-UI" "$def_pass" ADMIN_PASSWORD || return $?

            ensure_panel_path || return 1
            local r_path="$RAW_PATH"
            prompt_default "  Секретный URI-путь к веб-панели (без слэшей)" "$r_path" RAW_PATH || return $?
            validate_path_segment "$RAW_PATH" "URI панели"
            PANEL_PATH="/${RAW_PATH#/}"; PANEL_PATH="${PANEL_PATH%/}/"

            prompt_default "  Внутренний порт сервера подписок 3X-UI" "${SUB_PORT:-55443}" SUB_PORT || return $?
            local rand_s_path="sub-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "sub${RANDOM}")"
            local r_sub="${RAW_SUB_PATH:-${SUB_PATH:-$rand_s_path}}"
            r_sub="${r_sub#/}"; r_sub="${r_sub%/}"
            prompt_default "  Секретный URI-путь подписок (без слэшей)" "$r_sub" RAW_SUB_PATH || return $?
            validate_path_segment "$RAW_SUB_PATH" "URI подписок"
            SUB_PATH="/${RAW_SUB_PATH#/}"; SUB_PATH="${SUB_PATH%/}/"
            SUB_JSON_PATH="${SUB_PATH%/}/json/"
            SUB_CLASH_PATH="${SUB_PATH%/}/clash/"
            prompt_default "  Заголовок подписки для клиентов (Enter - без заголовка)" "${SUB_TITLE:-}" SUB_TITLE || return $?

            prompt_default "  Внутренний порт инбаунда VLESS xHTTP" "${XHTTP_STREAM_PORT:-50443}" XHTTP_STREAM_PORT || return $?
            local rand_x_path="$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "xh${RANDOM}")"
            local r_xhttp="${RAW_XHTTP_STREAM_PATH:-${XHTTP_STREAM_PATH:-$rand_x_path}}"
            r_xhttp="${r_xhttp#/}"; r_xhttp="${r_xhttp%/}"
            prompt_default "  URI-путь для xHTTP Stream-One" "$r_xhttp" RAW_XHTTP_STREAM_PATH || return $?
            validate_path_segment "$RAW_XHTTP_STREAM_PATH" "URI xHTTP"
            XHTTP_STREAM_PATH="/${RAW_XHTTP_STREAM_PATH#/}"; XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH%/}/"
        else
            PANEL_PORT="${PANEL_PORT:-10443}"
            ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
            [ -n "${ADMIN_PASSWORD:-}" ] || ADMIN_PASSWORD="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 12 || echo "Admin1234567")"

            ensure_panel_path || return 1
            validate_path_segment "$RAW_PATH" "URI панели"

            SUB_PORT="${SUB_PORT:-55443}"
            [ -n "${RAW_SUB_PATH:-}" ] || RAW_SUB_PATH="sub-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "sub${RANDOM}")"
            RAW_SUB_PATH="${RAW_SUB_PATH#/}"; RAW_SUB_PATH="${RAW_SUB_PATH%/}"
            SUB_PATH="/${RAW_SUB_PATH#/}"; SUB_PATH="${SUB_PATH%/}/"
            SUB_JSON_PATH="${SUB_PATH%/}/json/"
            SUB_CLASH_PATH="${SUB_PATH%/}/clash/"

            XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
            [ -n "${RAW_XHTTP_STREAM_PATH:-}" ] || RAW_XHTTP_STREAM_PATH="$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "xh${RANDOM}")"
            RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH#/}"; RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH%/}"
            XHTTP_STREAM_PATH="/${RAW_XHTTP_STREAM_PATH#/}"; XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH%/}/"

            echo -e "  ${GREEN}${CHECK} Настройки применены автоматически:${NC}"
            echo -e "    ${DIM}• Порты:${NC}   Панель :$PANEL_PORT, Подписки :$SUB_PORT, xHTTP :$XHTTP_STREAM_PORT"
            echo -e "    ${DIM}• Пути:${NC}    Панель: $PANEL_PATH, Подписки: $SUB_PATH, Clash: $SUB_CLASH_PATH, xHTTP: $XHTTP_STREAM_PATH"
            echo -e "    ${DIM}• Доступ:${NC}  Логин: ${BOLD}$ADMIN_USERNAME${NC}, Пароль: ${YELLOW}$ADMIN_PASSWORD${NC}"
        fi

        ok "Внутренние порты и пути сконфигурированы."
        return 0
    }

    q_step_protocols() {
        echo
        echo -e "${YELLOW}━━━ Шаг 5/13: Выбор протоколов и транспортов (VPN / Прокси) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Выберите протоколы подключения, которые будут развернуты на сервере."
            echo -e "     • ${GREEN}Hysteria 2${NC}: сверхбыстрый QUIC/UDP протокол с BBR Brutal для стриминга и мобильного интернета."
            echo -e "     • ${GREEN}AmneziaWG v3.1${NC}: защита от блокировок ТСПУ/DPI с обфускацией пакетов (внутри 3X-UI)."
            echo -e "     • ${GREEN}AmneziaWG v2.0${NC}: совместимость со старыми роутерами (Keenetic, OpenWrt)."
            echo -e "     • ${GREEN}Автономный AmneziaWG${NC}: независимый сервис ядра Linux (awg-quick@awg0, утилита awg-mgr)."
            echo -e "     • ${GREEN}TUIC v5${NC}: 0-RTT рукопожатие на чистом QUIC для мгновенного отклика."
            echo -e "     • ${GREEN}Shadowsocks 2022${NC}: устойчивый к зондированию шифрованный протокол."
            echo -e "     • ${GREEN}Telegram MTProxy${NC}: прямой доступ для клиентов Telegram без дополнительных VPN-приложений."
            echo -e "     • ${GREEN}MASQUE (RFC 9484)${NC}: стандартизированный IETF CONNECT-UDP/IP прокси поверх HTTP/3 QUIC."
            echo -e "     • ${GREEN}ShadowTLS v4${NC}: идеальная маскировка под Apple gateway.icloud.com через Nginx Stream L4."
            echo -e "     • ${GREEN}Wstunnel (Nginx L7)${NC}: WebSocket туннелирование через порт 443 HTTPS с валидным SSL."
            echo -e "     • ${GREEN}Server-Side Zapret${NC}: десинхронизация DPI ТСПУ прямо на VPS через nfqws connbytes 1:6."
            echo -e "     • ${GREEN}NaïveProxy${NC}: маскировка под Chrome HTTP/2/3 HTTPS (Chromium network stack via Caddy)."
            echo -e "     • ${GREEN}DNSTT (DoH Tunnel)${NC}: аварийный DNS-туннель через DoH (dnstt-server) для обхода жестких белых списков."
            echo
        fi

        local proto_keys=(
            "ENABLE_HY2"
            "ENABLE_AWG_V3"
            "ENABLE_AWG_V2"
            "ENABLE_AWG_STANDALONE"
            "ENABLE_TUIC"
            "ENABLE_SS2022"
            "ENABLE_MTPROTO"
            "ENABLE_MASQUE"
            "ENABLE_SHADOWTLS"
            "ENABLE_WSTUNNEL"
            "ENABLE_ZAPRET"
            "ENABLE_NAIVE"
            "ENABLE_DNSTT"
        )
        local proto_labels=(
            "Hysteria 2 (UDP/QUIC Brutal CC, :${HY2_PORT:-443})"
            "AmneziaWG v3.1 (инбаунд 3X-UI, :${AWG_V3_PORT:-8443}/udp)"
            "AmneziaWG v2.0 (роутеры Keenetic/OpenWrt, :${AWG_V2_PORT:-8444}/udp)"
            "Автономный сервер AmneziaWG (awg-mgr, :${AWG_STANDALONE_PORT:-8445}/udp)"
            "TUIC v5 (QUIC 0-RTT + BBR, :${TUIC_PORT:-8448}/udp)"
            "Shadowsocks 2022 (2022-blake3-aes-256-gcm, :${SS2022_PORT:-8388})"
            "Telegram MTProxy (FakeTLS прямой доступ, :${MTPROTO_PORT:-8444}/tcp)"
            "MASQUE (RFC 9484 / RFC 9298 via Sing-box, :${MASQUE_PORT:-8445}/udp)"
            "ShadowTLS v4 + SS-2022 (Nginx Stream :443 SNI ${SHADOWTLS_SNI:-gateway.icloud.com})"
            "Wstunnel over Nginx L7 (HTTPS WebSocket :443 -> :${WSTUNNEL_PORT:-8080})"
            "Server-Side Zapret (DPI Desync nfqws connbytes 1:6 NFQUEUE 200)"
            "NaïveProxy (Chromium HTTPS Stack via Caddy, Nginx Stream :443 -> :${NAIVE_PORT:-8446})"
            "DNSTT DoH Tunnel (DNS Tunneling via dnstt-server, :${DNSTT_PORT:-53053}/udp -> SS-2022)"
        )

        prompt_multiselect "Выберите протоколы для установки" proto_keys proto_labels || return $?

        # Установка портов по умолчанию и опрос кастомных параметров в экспертном режиме
        if is_true "$ENABLE_HY2"; then
            [ -n "${HY2_PORT:-}" ] || HY2_PORT="443"
            [ -n "${HY2_DOMAIN:-}" ] || HY2_DOMAIN="$PRIMARY_DOMAIN"
            HY2_PORT_HOPPING="${HY2_PORT_HOPPING:-n}"
            HY2_PORT_HOPPING_RANGE="${HY2_PORT_HOPPING_RANGE:-20000:50000}"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  UDP-порт для Hysteria 2" "$HY2_PORT" HY2_PORT || return $?
                prompt_default "  Домен/поддомен для Hysteria 2" "$HY2_DOMAIN" HY2_DOMAIN || return $?
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
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  UDP-порт для AmneziaWG v3.1 (3X-UI)" "$AWG_V3_PORT" AWG_V3_PORT || return $?
            fi
        else
            AWG_V3_PORT=""
        fi

        if is_true "$ENABLE_AWG_V2"; then
            [ -n "${AWG_V2_PORT:-}" ] || AWG_V2_PORT="8444"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  UDP-порт для AmneziaWG v2.0 (3X-UI)" "$AWG_V2_PORT" AWG_V2_PORT || return $?
            fi
        else
            AWG_V2_PORT=""
        fi

        if is_true "$ENABLE_AWG_STANDALONE"; then
            [ -n "${AWG_STANDALONE_PORT:-}" ] || AWG_STANDALONE_PORT="8445"
            [ -n "${AWG_SERVER_HOST:-}" ] || AWG_SERVER_HOST="${PRIMARY_DOMAIN:-$WAN_IP}"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  UDP-порт для автономного AmneziaWG" "$AWG_STANDALONE_PORT" AWG_STANDALONE_PORT || return $?
                prompt_default "  Хост/IP для подключения клиентов AmneziaWG" "$AWG_SERVER_HOST" AWG_SERVER_HOST || return $?
            fi
        else
            AWG_STANDALONE_PORT=""
        fi


        if is_true "$ENABLE_TUIC"; then
            [ -n "${TUIC_PORT:-}" ] || TUIC_PORT="8448"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  UDP-порт для TUIC v5" "$TUIC_PORT" TUIC_PORT || return $?
            fi
        else
            TUIC_PORT=""
        fi

        if is_true "$ENABLE_SS2022"; then
            [ -n "${SS2022_PORT:-}" ] || SS2022_PORT="8388"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  Порт для Shadowsocks 2022 (TCP/UDP)" "$SS2022_PORT" SS2022_PORT || return $?
            fi
        else
            SS2022_PORT=""
        fi

        if is_true "$ENABLE_MTPROTO"; then
            [ -n "${MTPROTO_PORT:-}" ] || MTPROTO_PORT="8444"
            [ -n "${MTPROTO_FAKETLS_DOMAIN:-}" ] || MTPROTO_FAKETLS_DOMAIN="gateway.icloud.com"
            MTPROTO_ADTAG="${MTPROTO_ADTAG:-}"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  TCP-порт для Telegram MTProxy" "$MTPROTO_PORT" MTPROTO_PORT || return $?
                prompt_default "  FakeTLS домен маскировки для MTProxy" "$MTPROTO_FAKETLS_DOMAIN" MTPROTO_FAKETLS_DOMAIN || return $?
                prompt_default "  Спонсорский promo-тег adTag (опционально, 32 hex)" "$MTPROTO_ADTAG" MTPROTO_ADTAG || return $?
            fi
        else
            MTPROTO_PORT=""
            MTPROTO_FAKETLS_DOMAIN=""
            MTPROTO_ADTAG=""
        fi

        if is_true "$ENABLE_MASQUE"; then
            [ -n "${MASQUE_PORT:-}" ] || MASQUE_PORT="8445"
            [ -n "${MASQUE_USER:-}" ] || MASQUE_USER="client"
            [ -n "${MASQUE_PASSWORD:-}" ] || MASQUE_PASSWORD="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "masque${RANDOM}")"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  UDP-порт для MASQUE (HTTP/3)" "$MASQUE_PORT" MASQUE_PORT || return $?
                prompt_default "  Имя пользователя для MASQUE" "$MASQUE_USER" MASQUE_USER || return $?
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
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  Локальный порт для ShadowTLS" "$SHADOWTLS_PORT" SHADOWTLS_PORT || return $?
                prompt_default "  FakeTLS SNI для ShadowTLS" "$SHADOWTLS_SNI" SHADOWTLS_SNI || return $?
            fi
        else
            SHADOWTLS_PORT=""
            SHADOWTLS_SNI=""
        fi

        if is_true "$ENABLE_WSTUNNEL"; then
            [ -n "${WSTUNNEL_PORT:-}" ] || WSTUNNEL_PORT="8080"
            ensure_wstunnel_prefix || return 1
            [ -n "${WSTUNNEL_SECRET:-}" ] || WSTUNNEL_SECRET="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 16 || echo "wst${RANDOM}")"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  Локальный порт для Wstunnel daemon" "$WSTUNNEL_PORT" WSTUNNEL_PORT || return $?
                prompt_default "  HTTP-путь location для Wstunnel" "$WSTUNNEL_PREFIX" WSTUNNEL_PREFIX || return $?
            fi
        else
            WSTUNNEL_PORT=""
            WSTUNNEL_PREFIX=""
        fi

        if is_true "$ENABLE_ZAPRET"; then
            [ -n "${ZAPRET_QNUM:-}" ] || ZAPRET_QNUM="200"
            [ -n "${ZAPRET_DESYNC:-}" ] || ZAPRET_DESYNC="split2"
            [ -n "${ZAPRET_FOOLING:-}" ] || ZAPRET_FOOLING="md5sig,badseq"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  Очередь NFQUEUE для Zapret" "$ZAPRET_QNUM" ZAPRET_QNUM || return $?
                prompt_default "  Режим desync для nfqws" "$ZAPRET_DESYNC" ZAPRET_DESYNC || return $?
                prompt_default "  Режим fooling для nfqws" "$ZAPRET_FOOLING" ZAPRET_FOOLING || return $?
            fi
        else
            ZAPRET_QNUM=""
        fi

        if is_true "$ENABLE_NAIVE"; then
            [ -n "${NAIVE_PORT:-}" ] || NAIVE_PORT="8446"
            [ -n "${NAIVE_USER:-}" ] || NAIVE_USER="user"
            [ -n "${NAIVE_DOMAIN:-}" ] || NAIVE_DOMAIN="naive.${PRIMARY_DOMAIN:-}"
            [ -n "${NAIVE_PASS:-}" ] || NAIVE_PASS="$(python3 -c 'import secrets; print(secrets.token_urlsafe(16))' 2>/dev/null || openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' || echo "nv${RANDOM}")"
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  Локальный порт для NaïveProxy (Caddy)" "$NAIVE_PORT" NAIVE_PORT || return $?
                prompt_default "  SNI-домен для NaïveProxy" "$NAIVE_DOMAIN" NAIVE_DOMAIN || return $?
                prompt_default "  Пользователь для NaïveProxy" "$NAIVE_USER" NAIVE_USER || return $?
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
            if [ "${PORTS_SETUP_MODE:-1}" = "2" ]; then
                prompt_default "  UDP-порт для DNSTT-сервера" "$DNSTT_PORT" DNSTT_PORT || return $?
                prompt_default "  NS/DNS-домен зоны для DNSTT" "$DNSTT_DOMAIN" DNSTT_DOMAIN || return $?
            fi
        else
            DNSTT_PORT=""
            DNSTT_DOMAIN=""
        fi

        rebuild_all_domains
        return 0
    }

    q_step_awg_v3() {
        prompt_yes_no "Установить и настроить AmneziaWG v3.1 (инбаунд 3X-UI)?" "${ENABLE_AWG_V3:-y}" ENABLE_AWG_V3 || return $?
        if is_true "${ENABLE_AWG_V3:-y}"; then
            ENABLE_AWG_V3=1

            prompt_default "  Внешний UDP-порт для AmneziaWG v3.1 (3X-UI)" "${AWG_V3_PORT:-8443}" AWG_V3_PORT || return $?
        else
            ENABLE_AWG_V3=0
            AWG_V3_PORT=""
        fi
        return 0
    }

    q_step_awg_v2() {
        prompt_yes_no "Установить и настроить AmneziaWG v2.0 (для роутеров Keenetic / OpenWrt, инбаунд 3X-UI)?" "${ENABLE_AWG_V2:-n}" ENABLE_AWG_V2 || return $?
        if is_true "${ENABLE_AWG_V2:-y}"; then
            ENABLE_AWG_V2=1

            prompt_default "  Внешний UDP-порт для AmneziaWG v2.0 (3X-UI)" "${AWG_V2_PORT:-8444}" AWG_V2_PORT || return $?
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
        echo -e "${YELLOW}━━━ Шаг 6/13: Настройка приватного AdGuard Home DoH + Split-DNS ━━━${NC}"
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
        echo -e "${YELLOW}━━━ Шаг 7/13: Выбор темы для сайта-маскировки (Decoy Site) ━━━${NC}"
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
        echo -e "${YELLOW}━━━ Шаг 8/13: Реестр SSL-сертификатов и дополнительные домены ━━━${NC}"
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
        echo -e "${YELLOW}━━━ Шаг 9/13: Выбор метода выпуска SSL-сертификатов ━━━${NC}"
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
        echo -e "${YELLOW}━━━ Шаг 10/13: Автоматическая настройка базы данных панели 3X-UI ━━━${NC}"
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
                if [[ "${PORTS_SETUP_MODE:-1}" == "2" ]]; then
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
        echo -e "${YELLOW}━━━ Шаг 11/13: Исходящий туннель Cloudflare WARP ━━━${NC}"
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
        echo -e "${YELLOW}━━━ Шаг 12/13: Безопасность сервера (SSH и Fail2ban) ━━━${NC}"
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
                        for reserved in 80 443 "${PANEL_PORT:-10443}" "${SUB_PORT:-55443}" "${XHTTP_STREAM_PORT:-50443}" "${HY2_PORT:-443}" "${AWG_V3_PORT:-8443}" "${AWG_V2_PORT:-8444}" "${AWG_STANDALONE_PORT:-8445}" "${SS2022_PORT:-8388}" "${TUIC_PORT:-8448}"; do
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

        local steal_status="${RED}Отключен${NC}"
        if is_true "${STEAL_ENABLED:-0}"; then
            steal_status="${GREEN}Включен${NC} (${WHITE}${STEAL_DOMAINS[*]}${NC} -> 127.0.0.1:${STEAL_PORTS_LIST[*]})"
        fi
        echo -e "  ${CYAN}[2]${NC} ${BOLD}REALITY (свой сайт):${NC}  $steal_status"

        local classic_status="${RED}Отключен${NC}"
        if is_true "${CLASSIC_ENABLED:-0}"; then
            classic_status="${GREEN}Включен${NC} (SNI: ${WHITE}${EXT_SNI_LIST[*]}${NC} -> 127.0.0.1:${CLASSIC_PORTS_LIST[*]})"
        fi
        echo -e "  ${CYAN}[3]${NC} ${BOLD}REALITY (внешний):${NC}    $classic_status"

        echo -e "  ${CYAN}[4]${NC} ${BOLD}Внутренние порты:${NC}     Панель :${WHITE}$PANEL_PORT${NC} (${DIM}$PANEL_PATH${NC}), Подписки :${WHITE}$SUB_PORT${NC} (${DIM}$SUB_PATH, Clash: $SUB_CLASH_PATH${NC}), xHTTP :${WHITE}$XHTTP_STREAM_PORT${NC}"
        echo -e "      ${DIM}Доступ в 3X-UI:${NC}       Логин: ${WHITE}$ADMIN_USERNAME${NC}, Пароль: ${YELLOW}$ADMIN_PASSWORD${NC}"

        echo -e "  ${CYAN}[5]${NC} ${BOLD}Протоколы VPN/Прокси:${NC}"
        local hy2_status="${RED}Отключена${NC}"
        if is_true "${ENABLE_HY2:-0}"; then
            local hop_str=""
            [ "$HY2_PORT_HOPPING" = "y" ] && hop_str=" + Hopping $HY2_PORT_HOPPING_RANGE"
            hy2_status="${GREEN}Включена${NC} (:${HY2_PORT}/udp, ${HY2_DOMAIN}${hop_str})"
        fi
        echo -e "      ${DIM}• Hysteria 2:${NC}           $hy2_status"

        local awg3_status="${RED}Отключен${NC}"
        is_true "${ENABLE_AWG_V3:-0}" && awg3_status="${GREEN}Включен${NC} (:${AWG_V3_PORT}/udp)"
        echo -e "      ${DIM}• AmneziaWG v3.1 (3X-UI):${NC} $awg3_status"

        local awg2_status="${RED}Отключен${NC}"
        is_true "${ENABLE_AWG_V2:-0}" && awg2_status="${GREEN}Включен${NC} (:${AWG_V2_PORT}/udp)"
        echo -e "      ${DIM}• AmneziaWG v2.0 (3X-UI):${NC} $awg2_status"

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
        is_true "${ENABLE_MASQUE:-0}" && masque_status="${GREEN}Включен${NC} (:${MASQUE_PORT:-8445}/udp, RFC 9484)"
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

        local agh_status="${RED}Отключен${NC}"
        if is_true "${ENABLE_AGH:-0}"; then
            local m_desc="Основной домен"
            [ "$AGH_MODE" = "2" ] && m_desc="Поддомен $AGH_DOMAIN"
            agh_status="${GREEN}Включен${NC} (Режим: $m_desc, ClientID: $AGH_CLIENT_ID)"
        fi
        echo -e "  ${CYAN}[6]${NC} ${BOLD}AdGuard Home DoH:${NC}     $agh_status"

        local decoy_name="DataSphere Analytics"
        [ "$DECOY_MODE" = "2" ] && decoy_name="CosmosCloud NextGen"
        [ "$DECOY_MODE" = "3" ] && decoy_name="Стандартная заглушка Nginx"
        echo -e "  ${CYAN}[7]${NC} ${BOLD}Тема маскировки:${NC}      ${WHITE}$decoy_name${NC}"

        echo -e "  ${CYAN}[8]${NC} ${BOLD}SSL-домены (${#ALL_DOMAINS[@]}):${NC}   ${WHITE}${ALL_DOMAINS[*]}${NC}"

        local ssl_name="Certbot (HTTP-01)"
        [ "$SSL_ENGINE_CHOICE" = "2" ] && ssl_name="acme.sh + Cloudflare DNS-01"
        echo -e "  ${CYAN}[9]${NC} ${BOLD}Метод выпуска SSL:${NC}    ${WHITE}$ssl_name${NC}"

        local auto_3xui_str="${GREEN}Да${NC}"
        is_true "${AUTO_SETUP_3XUI:-y}" || auto_3xui_str="${RED}Нет${NC}"
        if is_true "${ENABLE_NODE_TOKEN:-n}"; then
            auto_3xui_str="${auto_3xui_str} ${DIM}(+ Node Token: ${WHITE}${NODE_TOKEN_NAME}${DIM})${NC}"
        fi
        echo -e "  ${CYAN}[10]${NC} ${BOLD}3X-UI автонастройка:${NC}  $auto_3xui_str"

        local warp_status="${RED}Отключен${NC}"
        is_true "${ENABLE_WARP:-n}" && warp_status="${GREEN}Включен${NC} (WireGuard MTU: 1280)"
        echo -e "  ${CYAN}[11]${NC} ${BOLD}Cloudflare WARP:${NC}      $warp_status"

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
        echo -e "  ${CYAN}[12]${NC} ${BOLD}Безопасность сервера:${NC}    $sec_status"

        echo
        echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "  ${GREEN}[Enter]${NC} или ${GREEN}[y]${NC}  ${BOLD}Проверить параметры и перейти к плану установки${NC}"
        echo -e "  ${CYAN}[1 - 12]${NC}        ${BOLD}Изменить соответствующий раздел конфигурации${NC}"
        echo -e "  ${RED}[q]${NC}             ${BOLD}Отмена и выход${NC}"
        echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════${NC}"
        echo

        while true; do
            local choice=""
            echo -ne "  ${WHITE}${ARROW} Ваш выбор [${GREEN}Enter = далее${WHITE}]: ${NC}"
            read -r choice </dev/tty || read -r choice || true
            choice=$(echo "${choice:-}" | tr -d '[:space:]')

            if [ -z "$choice" ] || [[ "${choice,,}" == "y" ]] || [[ "${choice,,}" == "yes" ]]; then
                return 0
            fi

            if [[ "${choice,,}" == "q" || "${choice,,}" == "quit" || "${choice,,}" == "exit" ]]; then
                die "Установка отменена пользователем."
            fi

            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le 12 ]; then
                return $((100 + choice))
            fi

            warn "  Некорректный ввод. Нажмите Enter для старта, номер [1-12] для изменения или 'q' для выхода."
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
            CURRENT_STEP=13
            EDITING_FROM_REVIEW=0
        else
            CURRENT_STEP=1
            EDITING_FROM_REVIEW=0
        fi
        TOTAL_STEPS=13

        while [ "$CURRENT_STEP" -le "$TOTAL_STEPS" ]; do
            res=0
            case "$CURRENT_STEP" in
                1) q_step_domain || res=$? ;;
                2) q_step_steal || res=$? ;;
                3) q_step_classic || res=$? ;;
                4) q_step_ports || res=$? ;;
                5) q_step_protocols || res=$? ;;
                6) q_step_agh || res=$? ;;
                7) q_step_decoy || res=$? ;;
                8) q_step_ssl_domains || res=$? ;;
                9) q_step_ssl_engine || res=$? ;;
                10) q_step_3xui_auto || res=$? ;;
                11) q_step_warp || res=$? ;;
                12) q_step_security || res=$? ;;
                13) q_step_review || res=$? ;;
            esac

            if [ "$res" -eq 10 ]; then
                # Запрос перехода назад
                if [ "$EDITING_FROM_REVIEW" -eq 1 ]; then
                    CURRENT_STEP=13
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
            elif [ "$res" -ge 101 ] && [ "$res" -le 112 ]; then
                # Переход к конкретному шагу из экрана Review
                CURRENT_STEP=$((res - 100))
                EDITING_FROM_REVIEW=1
            elif [ "$res" -eq 0 ]; then
                if [ "$CURRENT_STEP" -eq 13 ]; then
                    break
                elif [ "$EDITING_FROM_REVIEW" -eq 1 ]; then
                    CURRENT_STEP=13
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
