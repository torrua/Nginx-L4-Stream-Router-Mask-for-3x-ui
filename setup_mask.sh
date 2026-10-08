#!/usr/bin/env bash
#
# ==============================================================================
# Production AutoSetup: Hardened Engine v7.2.1 Universal (Public Edition)
# Nginx L4 Stream + 3X-UI + Unix Sockets + Native proxy_http_version 2 + 3 Decoys
# ==============================================================================
# Архитектура:
#   1) Nginx Mainline Branch v.1.31.4+ (Официальный репозиторий nginx.org)
#   2) Steal-Oneself REALITY с защитой от зацикливания (Anti-Loop Fallback 9443)
#   3) Classic External REALITY (Выделение портов для внешних SNI)
#   4) VLESS xHTTP (Stream-One) + VLESSENC + Native H2 Streaming (без XMUX-блокировок)
#      (СТРОГО по TCP/HTTP/2 без QUIC — полнодуплексное H2C-проксирование Nginx)
#   5) Опциональный скоростной UDP VPN: Hysteria 2 (по умолчанию 443/UDP)
#   6) Опциональный двухверсионный стек AmneziaWG / WireGuard:
#      - AmneziaWG v3.1 (WG3, по умолчанию 8443/UDP, Transport Protection)
#      - AmneziaWG v2.0 / Legacy 1.0 (по умолчанию 8444/UDP, для роутеров)
#   7) Гибридный SSL-движок с разделением каталогов:
#      - Certbot (HTTP-01): /etc/letsencrypt/live/
#      - acme.sh + Cloudflare (DNS-01): /etc/ssl/acme/ (изоляция от /root/ и 755/644)
#   8) 3 автономных локальных режима маскировки (Decoy Front):
#      - 1: DataSphere Analytics (SPA с 3D-сферой и телеметрией)
#      - 2: Облако CosmosCloud 
#      - 3: Стандартная заглушка Nginx (Welcome to nginx)
#   9) Комплексная защита от ботов, сканеров уязвимостей, AI-парсеров (444/404)
#  10) Полный тюнинг ядра Linux (TCP BBR, fq, somaxconn, lowat, IPC /dev/shm, UDP buffers)
#  ==============================================================================

set -euo pipefail

SCRIPT_VERSION="v7.3.0"

# --------------------------- Замеры времени и телеметрия ---------------------------
SCRIPT_START_TIME=$(date +%s)
SCRIPT_START_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')

TOTAL_STEPS=7
LAST_COMPLETED_STEP=${LAST_COMPLETED_STEP:-0}
RESUME_STEP=${RESUME_STEP:-1}
RESUME_MODE=${RESUME_MODE:-0}
CURRENT_STEP_START=0

declare -A STEP_DURATIONS=()
declare -A STEP_BG_FLAGS=()
declare -A DOMAIN_TO_PORT=()
declare -A EXT_SNI_TO_PORT=()
declare -A STEP_NAMES=(
    [1]="Установка базовых системных зависимостей"
    [2]="Оптимизация сетевого стека ядра Linux (BBR + fq + MSS Clamping)"
    [3]="Подключение репозитория и установка Nginx Mainline"
    [4]="Выпуск SSL-сертификатов Let's Encrypt"
    [5]="Развертывание сайта-маскировки (Decoy Front)"
    [6]="Сборка конфигурации Nginx и активация маршрутизатора"
    [7]="Автоматическая настройка базы данных 3X-UI"
    [8]="Приватный AdGuard Home DoH + Split-DNS"
)

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

record_step_completed() {
    local step_num="$1"
    LAST_COMPLETED_STEP="$step_num"
    local cfg="${SAVED_CONFIG_FILE:-./setup_mask.env}"
    if [ -f "$cfg" ]; then
        if grep -q "^LAST_COMPLETED_STEP=" "$cfg"; then
            sed -i "s/^LAST_COMPLETED_STEP=.*/LAST_COMPLETED_STEP=\"$step_num\"/" "$cfg"
        else
            echo "LAST_COMPLETED_STEP=\"$step_num\"" >> "$cfg"
        fi
    fi
}

should_skip_step() {
    local step_num="$1"
    local step_title="${STEP_NAMES[$step_num]:-${2:-Шаг $step_num}}"
    if [ "${RESUME_STEP:-1}" -gt "$step_num" ]; then
        # Проверка фактического наличия артефактов шага на диске
        local state_valid=1
        local missing_reason=""

        case "$step_num" in
            1)
                if ! command -v curl >/dev/null 2>&1 || ! command -v socat >/dev/null 2>&1; then
                    state_valid=0
                    missing_reason="базовые утилиты (curl/socat) не найдены"
                fi
                ;;
            2)
                if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
                    state_valid=0
                    missing_reason="TCP BBR не активен в sysctl"
                fi
                ;;
            3)
                if ! command -v nginx >/dev/null 2>&1; then
                    state_valid=0
                    missing_reason="бинарный файл nginx не найден"
                fi
                ;;
            4)
                local cert_file=""
                if [ "${SSL_ENGINE_CHOICE:-1}" = "1" ]; then
                    cert_file="/etc/letsencrypt/live/${PRIMARY_DOMAIN:-}/fullchain.pem"
                else
                    cert_file="/etc/ssl/acme/${PRIMARY_DOMAIN:-}/fullchain.pem"
                fi
                if [ -z "${PRIMARY_DOMAIN:-}" ] || [ ! -f "$cert_file" ]; then
                    state_valid=0
                    missing_reason="SSL-сертификат для $PRIMARY_DOMAIN отсутствует ($cert_file)"
                fi
                ;;
            5)
                if [ ! -f "/var/www/html/index.html" ]; then
                    state_valid=0
                    missing_reason="веб-маска /var/www/html/index.html не найдена"
                fi
                ;;
            6)
                if [ ! -f "/etc/nginx/stream.d/00-stream.conf" ] || [ ! -f "/etc/nginx/conf.d/01-main.conf" ] || [ ! -f "/etc/nginx/nginx.conf" ]; then
                    state_valid=0
                    missing_reason="конфигурации Nginx (00-stream.conf / 01-main.conf) отсутствуют"
                fi
                ;;
            7)
                if [ ! -f "/etc/x-ui/x-ui.db" ] && [ ! -f "/usr/local/x-ui/bin/x-ui.db" ]; then
                    state_valid=0
                    missing_reason="база данных 3X-UI x-ui.db не найдена"
                fi
                ;;
            8)
                if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
                    if [ ! -f "/opt/AdGuardHome/AdGuardHome.yaml" ]; then
                        state_valid=0
                        missing_reason="конфигурация AdGuardHome.yaml не найдена"
                    fi
                fi
                ;;
        esac

        if [ "$state_valid" -eq 1 ]; then
            print_step_bar "$step_num" "$TOTAL_STEPS" "$step_title [Уже выполнен ранее]"
            ok "$step_title — пропущено (файлы и сервисы проверены на диске)"
            STEP_DURATIONS[$step_num]=0
            return 0
        else
            warn "Шаг $step_num ($step_title) был отмечен завершенным, но $missing_reason."
            log "Повторное выполнение шага $step_num для восстановления целостности..."
            return 1
        fi
    fi
    return 1
}

step_begin() {
    local step_num="$1"
    local step_title="${STEP_NAMES[$step_num]:-$2}"
    CURRENT_STEP_START=$(date +%s)
    print_step_bar "$step_num" "$TOTAL_STEPS" "$step_title"
}

step_finish() {
    local step_num="$1"
    local duration=0
    local is_bg=0
    local bg_dur_file="/tmp/setup_mask_bg_duration_${step_num}.time"
    if [ -f "$bg_dur_file" ]; then
        duration=$(cat "$bg_dur_file" 2>/dev/null | tr -d '[:space:]' || echo 0)
        if [[ "$duration" =~ ^[0-9]+$ ]] && [ "$duration" -gt 0 ]; then
            is_bg=1
            STEP_BG_FLAGS[$step_num]=1
        fi
        rm -f "$bg_dur_file" 2>/dev/null || true
    fi

    if [ "$is_bg" -eq 0 ]; then
        local step_end
        step_end=$(date +%s)
        duration=$(( step_end - CURRENT_STEP_START ))
        [ "$duration" -lt 0 ] && duration=0
    fi

    STEP_DURATIONS[$step_num]="$duration"
    local dur_str
    dur_str=$(format_duration "$duration")
    if [ "$is_bg" -eq 1 ]; then
        ok "Шаг $step_num из $TOTAL_STEPS: ${STEP_NAMES[$step_num]} [ГОТОВО] (в фоне за $dur_str, сэкономлено: 100%)"
    else
        ok "Шаг $step_num из $TOTAL_STEPS: ${STEP_NAMES[$step_num]} [ГОТОВО] (время: $dur_str)"
    fi
    record_step_completed "$step_num"
}


# --------------------------- Цвета и UI-движок ---------------------------
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
WHITE=$'\033[1;37m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
NC=$'\033[0m'

CHECK="✔"
CROSS="✖"
ARROW="➜"
STAR="★"

log()  { echo -e "  ${CYAN}[+]${NC} $*"; }
ok()   { echo -e "  ${GREEN}${CHECK}${NC} $*"; }
warn() { echo -e "  ${YELLOW}[!]${NC} $*"; }
die()  { echo -e "  ${RED}${CROSS} $*${NC}" >&2; exit 1; }

# Анимированный спиннер для фоновых операций
# При DEBUG_MODE=1: отключает спиннер, выполняет команды напрямую (весь вывод виден)
# При ошибке: выводит полный лог и вызывает меню повтора (Retry / Skip / Abort)
run_with_spinner() {
    local task_name="$1"
    shift
    local log_file="${SETUP_MASK_LOG:-/tmp/setup_mask_cmd.log}"

    while true; do
        local exit_code=0

        # ── DEBUG MODE: без фона, весь вывод сразу в stdout ──
        if [ "${DEBUG_MODE:-0}" -eq 1 ]; then
            echo -e "\n  ${CYAN}[DEBUG]${NC} ${WHITE}▶ $task_name${NC}"
            echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            if declare -f "$1" >/dev/null 2>&1; then
                "$@" || exit_code=$?
            else
                eval "$*" || exit_code=$?
            fi
            if [ $exit_code -eq 0 ]; then
                echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
                echo -e "  ${GREEN}${CHECK}${NC}  ${WHITE}$task_name${NC} ${GREEN}[ГОТОВО]${NC}\n"
                return 0
            else
                echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            fi
        else
            # ── Нормальный режим: фоновый процесс + спиннер ──
            local spin_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
            local delay=0.08

            : > "$log_file"

            if declare -f "$1" >/dev/null 2>&1; then
                "$@" >> "$log_file" 2>&1 &
            else
                ( eval "$*" ) >> "$log_file" 2>&1 &
            fi
            local pid=$!
            
            if [ ! -t 1 ]; then
                echo -e "  ${CYAN}*${NC}  ${WHITE}${task_name}...${NC}"
                wait "$pid"
                exit_code=$?
            else
                tput civis 2>/dev/null || echo -ne "\033[?25l"
                local i=0
                while kill -0 "$pid" 2>/dev/null; do
                    i=$(( (i + 1) % 10 ))
                    printf "\r  ${CYAN}${spin_chars[$i]}${NC}  ${WHITE}%-54s${NC}" "$task_name..."
                    sleep "$delay"
                done
                wait "$pid"
                exit_code=$?
                tput cnorm 2>/dev/null || echo -ne "\033[?25h"
            fi

            if [ $exit_code -eq 0 ]; then
                if [ ! -t 1 ]; then
                    printf "  ${GREEN}${CHECK}${NC}  ${WHITE}%-54s${NC} ${GREEN}[ГОТОВО]${NC}\n" "$task_name"
                else
                    printf "\r  ${GREEN}${CHECK}${NC}  ${WHITE}%-54s${NC} ${GREEN}[ГОТОВО]${NC}\n" "$task_name"
                fi
                return 0
            fi

            if [ ! -t 1 ]; then
                printf "  ${RED}${CROSS}${NC}  ${WHITE}%-54s${NC} ${RED}[ОШИБКА]${NC}\n" "$task_name"
            else
                printf "\r  ${RED}${CROSS}${NC}  ${WHITE}%-54s${NC} ${RED}[ОШИБКА]${NC}\n" "$task_name"
            fi
            echo -e "\n  ${RED}${BOLD}Полный лог ошибки:${NC}"
            echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            [ -f "$log_file" ] && cat "$log_file" | sed 's/^/    /' || true
            echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
            echo -e "  ${DIM}Совет: запустите с флагом ${WHITE}--debug${DIM} для подробного вывода в реальном времени.${NC}\n"
        fi

        # ── Интерактивная обработка сбоя (Retry / Skip / Abort) ──
        if [ "${NON_INTERACTIVE:-0}" -eq 0 ]; then
            echo -e "  ${YELLOW}${BOLD}Действия при сбое:${NC}"
            echo -e "    ${CYAN}${BOLD}[1] Повторить попытку (Retry)${NC} — после исправления причин (напр. DNS)"
            echo -e "    ${YELLOW}[2] Пропустить этот шаг и продолжить (Skip)${NC}"
            echo -e "    ${RED}[3] Прервать установку (Abort)${NC}"
            local retry_ans=""
            read -rp "  Ваш выбор [1/2/3] (по умолчанию: 1): " retry_ans </dev/tty || read -r retry_ans || retry_ans="1"
            retry_ans=$(echo "${retry_ans:-1}" | tr -d '[:space:]')
            case "$retry_ans" in
                2)
                    warn "Шаг '$task_name' пропущен по выбору пользователя."
                    return 0
                    ;;
                3)
                    die "Шаг завершился с ошибкой (exit $exit_code): $task_name"
                    ;;
                *)
                    echo -e "  ${CYAN}${ARROW} Повторная попытка: $task_name...${NC}\n"
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
Использование: ./setup_mask.sh [ОПЦИИ]

Автоматизированный и интерактивный установщик L4/L7 Nginx Router + 3X-UI

Опции:
  -c, --config <FILE>          Загрузить параметры из конфигурационного файла (.env)
  -y, --yes, --non-interactive Запуск в неинтерактивном режиме (без вопросов пользователю)
  -d, --domain <DOMAIN>        Указать основной домен (PRIMARY_DOMAIN)
  -r, --resume                 Продолжить установку с последнего незавершенного шага
  --step <N>                   Принудительно начать выполнение с указанного шага (1-8)
  --check, --doctor            Запустить быструю диагностику состояния сервисов и выйти
  --express                    Запустить режим Экспресс-настройки (настройка в 2 вопроса)
  --expert                     Запустить Экспертный режим без повторного запроса меню
  --gen-config [FILE]          Сгенерировать шаблон конфигурации (.env.example) и выйти
  --debug                      Режим отладки: отключить спиннеры, вывод команд в реальном времени
  -f, --force                  Игнорировать ошибки и несовпадения DNS в неинтерактивном режиме
  -v, --version                Показать версию скрипта и выйти
  -h, --help                   Показать справку и выйти

Примеры использования:
  # Интерактивный режим (введенные параметры автоматически сохраняются в setup_mask.env):
  ./setup_mask.sh

  # Быстрая экспресс-диагностика всех сервисов и портов:
  ./setup_mask.sh --check

  # Возобновление прерванной установки с последнего незавершенного шага:
  ./setup_mask.sh --resume

  # Принудительный запуск с определенного шага (напр. Шаг 4: Выпуск SSL):
  ./setup_mask.sh --step 4 -y

  # Возобновление после обрыва связи или повторный запуск из сохраненного конфига:
  ./setup_mask.sh -c setup_mask.env -y

  # Развертывание через Ansible / Cloud-Init / CI:
  ./setup_mask.sh --config /etc/setup_mask.env --non-interactive --force

  # Генерация файла-шаблона:
  ./setup_mask.sh --gen-config setup_mask.env.example
EOF_HELP
}

generate_config_template() {
    local target_file="${1:-setup_mask.env.example}"
    cat << 'EOF_CONF' > "$target_file"
# ==============================================================================
# КОНФИГУРАЦИЯ NGINX L4 ROUTER + 3X-UI ДЛЯ SETUP_MASK.SH (v7.2.0 Universal)
# ==============================================================================
# Данный файл позволяет выполнять полностью автоматическую установку:
# ./setup_mask.sh --config setup_mask.env --non-interactive --force

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
# Сценарий 1: Steal-Oneself REALITY (Кража у самого себя с Anti-Loop) [y/n]
ENABLE_STEAL="y"
STEAL_PORT="45443"
# Домены для Steal-Oneself (через пробел, например: "cdn.yourdomain.online")
STEAL_DOMAINS="cdn.yourdomain.online"

# Сценарий 2: Classic External REALITY (Внешний камуфляж) [y/n]
ENABLE_CLASSIC="y"
CLASSIC_PORT="46443"
# Внешние доверенные SNI (через пробел, например: "gateway.icloud.com")
CLASSIC_SNI="gateway.icloud.com"

# --- 3. ВНУТРЕННИЕ ПОРТЫ И ПУТИ 3X-UI И xHTTP ---
PANEL_PORT="10443"
PANEL_PATH="my-3x-panel"
# Учетные данные администратора панели 3X-UI
ADMIN_USERNAME="admin"
ADMIN_PASSWORD=""
# Префикс / название сервера для подключений (например: NL, DE, MyServer)
SERVER_PREFIX="Server"

SUB_PORT="55443"
SUB_PATH="my-post-key"
# Секретный путь для Clash/Mihomo подписок (по умолчанию: <SUB_PATH>clash)
SUB_CLASH_PATH=""

XHTTP_STREAM_PORT="50443"
XHTTP_STREAM_PATH="Stream-One-Path"

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

# AmneziaWG v2.0 / Legacy (Для роутеров) [y/n]
ENABLE_AWG_V2="y"
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
# Автоматически настроить инбаунды и пути подписок в базе данных 3X-UI через configure_3xui.sh [y/n]
AUTO_SETUP_3XUI="y"

# Создать API-токен для подключения сервера как узла (3X-UI Node) [y/n]
ENABLE_NODE_TOKEN="n"
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
AGH_CLIENT_ID="home-router"
# Использовать AdGuard Home как DNS для VPN-клиентов (Xray DNS → 127.0.0.1) [y/n]
AGH_XRAY_DNS="y"
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
            target_gen_file="setup_mask.env.example"
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
    RAW_SUB_PATH="${SUB_PATH:-${RAW_SUB_PATH:-my-post-key}}"
    RAW_SUB_PATH="${RAW_SUB_PATH#/}"
    RAW_SUB_PATH="${RAW_SUB_PATH%/}"
    SUB_PATH="/${RAW_SUB_PATH}/"
    SUB_JSON_PATH="${SUB_PATH}json/"
    local _c_path="${SUB_CLASH_PATH:-${RAW_SUB_CLASH_PATH:-${SUB_PATH}clash/}}"
    _c_path="${_c_path#/}"; _c_path="${_c_path%/}"
    SUB_CLASH_PATH="/${_c_path}/"

    XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
    RAW_XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH:-${RAW_XHTTP_STREAM_PATH:-Stream-One-Path}}"
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
    else
        ENABLE_HY2=0
    fi
    _v="${ENABLE_AWG_V3:-n}"; if is_true "$_v"; then ENABLE_AWG_V3=1; else ENABLE_AWG_V3=0; fi
    _v="${ENABLE_AWG_V2:-n}"; if is_true "$_v"; then ENABLE_AWG_V2=1; else ENABLE_AWG_V2=0; fi
    _v="${ENABLE_AGH:-n}"; if is_true "$_v"; then ENABLE_AGH=1; else ENABLE_AGH=0; fi
    _v="${ENABLE_WARP:-n}"; if is_true "$_v"; then ENABLE_WARP="y"; else ENABLE_WARP="n"; fi
    _v="${ENABLE_NODE_TOKEN:-n}"; if is_true "$_v"; then ENABLE_NODE_TOKEN="y"; else ENABLE_NODE_TOKEN="n"; fi
    _v="${AGH_XRAY_DNS:-n}"; if is_true "$_v"; then AGH_XRAY_DNS="y"; else AGH_XRAY_DNS="n"; fi
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

    local _save_xhttp_path="${RAW_XHTTP_STREAM_PATH:-${XHTTP_STREAM_PATH:-Stream-One-Path}}"
    _save_xhttp_path="${_save_xhttp_path#/}"
    _save_xhttp_path="${_save_xhttp_path%/}"

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

# ----------------- Обработка аргументов командной строки -----------------
CONFIG_FILE=""
NON_INTERACTIVE=${NON_INTERACTIVE:-0}
DEBUG_MODE=${DEBUG_MODE:-0}
EXPERT_MODE=${EXPERT_MODE:-0}
SHOW_TIPS=${SHOW_TIPS:-}
CHECK_MODE=0
GEN_CONFIG=0
FORCE_DNS=${FORCE_DNS:-0}
SAVED_CONFIG_FILE="setup_mask.env"

CLI_PRIMARY_DOMAIN=""
CLI_ADD_WWW=""
CLI_LE_EMAIL=""
CLI_PANEL_PORT=""
CLI_PANEL_PATH=""
CLI_ADMIN_USERNAME=""
CLI_ADMIN_PASSWORD=""
CLI_ENABLE_HY2=""

while [[ $# -gt 0 ]]; do
    case "$1" in
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
        --gen-config)
            GEN_CONFIG=1
            if [[ -n "${2:-}" && ! "$2" =~ ^- ]]; then
                TARGET_GEN_FILE="$2"
                shift 2
            else
                TARGET_GEN_FILE="setup_mask.env.example"
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
    if [ -f "./setup_mask.env" ]; then
        CONFIG_FILE="./setup_mask.env"
        log "Автообнаружен конфигурационный файл: $CONFIG_FILE"
    elif [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/setup_mask.env" ]; then
        CONFIG_FILE="$SCRIPT_DIR/setup_mask.env"
        log "Автообнаружен конфигурационный файл: $CONFIG_FILE"
    elif [ -f "/etc/setup_mask.env" ]; then
        CONFIG_FILE="/etc/setup_mask.env"
        log "Автообнаружен конфигурационный файл: $CONFIG_FILE"
    elif [ "$NON_INTERACTIVE" -eq 0 ] && [ -f "./.env" ]; then
        # В неинтерактивном режиме .env не загружается автоматически — только setup_mask.env
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
[ -n "${CLI_ADMIN_USERNAME:-}" ] && ADMIN_USERNAME="$CLI_ADMIN_USERNAME"
[ -n "${CLI_ADMIN_PASSWORD:-}" ] && ADMIN_PASSWORD="$CLI_ADMIN_PASSWORD"
[ -n "${CLI_ENABLE_HY2:-}" ]      && ENABLE_HY2="$CLI_ENABLE_HY2"

# Сессия всегда сохраняется в setup_mask.env в текущей папке или рядом со скриптом
SAVED_CONFIG_FILE="${CONFIG_FILE:-./setup_mask.env}"

# =============================================================
#  ФУНКЦИИ ДИАГНОСТИКИ, РЕЗЕРВНОГО КОПИРОВАНИЯ И SMOKE-TEST
# =============================================================

backup_nginx_configs() {
    local bkp_dir="/var/backups/nginx_mask"
    mkdir -p "$bkp_dir"
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    local bkp_file="$bkp_dir/nginx_conf_${ts}.tar.gz"

    local has_files=0
    if compgen -G "/etc/nginx/conf.d/*.conf" >/dev/null 2>&1 || compgen -G "/etc/nginx/stream.d/*.conf" >/dev/null 2>&1; then
        has_files=1
    fi

    if [ "$has_files" -eq 1 ]; then
        if tar -czf "$bkp_file" -C /etc/nginx conf.d stream.d 2>/dev/null; then
            local old_backups
            old_backups=$(ls -1t "$bkp_dir"/nginx_conf_*.tar.gz 2>/dev/null | tail -n +6 || true)
            if [ -n "$old_backups" ]; then
                echo "$old_backups" | xargs -r rm -f 2>/dev/null || true
            fi
            ok "Создана резервная копия конфигурации Nginx: $bkp_file (ротация: 5)"
        fi
    fi
}

post_install_sanity_check() {
    echo ""
    echo -e "  ${CYAN}${BOLD}🔍  ПРОВЕРКА РАБОТОСПОСОБНОСТИ СЕРВИСОВ (SMOKE TEST)${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"

    local all_ok=1

    # 1. Nginx служба и порт 443 TCP
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx 2>/dev/null; then
        ok "Служба Nginx: активна (running)"
    else
        warn "Служба Nginx: НЕ АКТИВНА!"
        all_ok=0
    fi

    if timeout 2 bash -c '</dev/tcp/127.0.0.1/443' 2>/dev/null; then
        ok "Порт 443 TCP (Nginx Stream Router): отвечает"
    else
        warn "Порт 443 TCP (Nginx Stream Router): НЕ ОТВЕЧАЕТ на 127.0.0.1!"
        all_ok=0
    fi

    if timeout 2 bash -c '</dev/tcp/127.0.0.1/80' 2>/dev/null; then
        ok "Порт 80 TCP (HTTP / ACME Redirect): отвечает"
    else
        warn "Порт 80 TCP (HTTP): НЕ ОТВЕЧАЕТ на 127.0.0.1!"
    fi

    # 2. Xray / 3X-UI
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet x-ui 2>/dev/null; then
        ok "Служба 3X-UI: активна (running)"
    else
        warn "Служба 3X-UI: НЕ АКТИВНА!"
        all_ok=0
    fi

    local steal_p="${STEAL_PORTS_LIST[0]:-${STEAL_PORT:-45443}}"
    local classic_p="${CLASSIC_PORTS_LIST[0]:-${CLASSIC_PORT:-46443}}"
    local xhttp_p="${XHTTP_STREAM_PORT:-50443}"
    local panel_p="${PANEL_PORT:-10443}"
    local sub_p="${SUB_PORT:-55443}"

    if [[ "${ENABLE_STEAL,,}" == "y" || "${ENABLE_STEAL:-}" == "1" ]]; then
        if timeout 2 bash -c "</dev/tcp/127.0.0.1/$steal_p" 2>/dev/null; then
            ok "Инбаунд Steal-Oneself REALITY (порт $steal_p): отвечает"
        else
            warn "Инбаунд Steal-Oneself REALITY (порт $steal_p): НЕ ОТВЕЧАЕТ!"
            all_ok=0
        fi
    fi

    if [[ "${ENABLE_CLASSIC,,}" == "y" || "${ENABLE_CLASSIC:-}" == "1" ]]; then
        if timeout 2 bash -c "</dev/tcp/127.0.0.1/$classic_p" 2>/dev/null; then
            ok "Инбаунд Classic REALITY (порт $classic_p): отвечает"
        else
            warn "Инбаунд Classic REALITY (порт $classic_p): НЕ ОТВЕЧАЕТ!"
            all_ok=0
        fi
    fi

    if timeout 2 bash -c "</dev/tcp/127.0.0.1/$xhttp_p" 2>/dev/null; then
        ok "Инбаунд VLESS xHTTP (порт $xhttp_p): отвечает"
    else
        warn "Инбаунд VLESS xHTTP (порт $xhttp_p): НЕ ОТВЕЧАЕТ!"
        all_ok=0
    fi

    if timeout 2 bash -c "</dev/tcp/127.0.0.1/$panel_p" 2>/dev/null; then
        ok "Панель 3X-UI (порт $panel_p): отвечает"
    else
        warn "Панель 3X-UI (порт $panel_p): НЕ ОТВЕЧАЕТ!"
    fi

    if timeout 2 bash -c "</dev/tcp/127.0.0.1/$sub_p" 2>/dev/null; then
        ok "Канал подписок 3X-UI (порт $sub_p): отвечает"
    else
        warn "Канал подписок 3X-UI (порт $sub_p): НЕ ОТВЕЧАЕТ!"
    fi

    # 3. UDP сервисы (Hysteria 2 / AmneziaWG)
    if [[ "${ENABLE_HY2,,}" == "y" || "${ENABLE_HY2:-}" == "1" ]]; then
        if ss -ulpn 2>/dev/null | grep -q ":${HY2_PORT:-443} "; then
            ok "Hysteria 2 UDP (порт ${HY2_PORT:-443}): слушает"
        fi
    fi
    if [[ "${ENABLE_AWG_V3,,}" == "y" || "${ENABLE_AWG_V3:-}" == "1" ]]; then
        if ss -ulpn 2>/dev/null | grep -q ":${AWG_V3_PORT:-8443} "; then
            ok "AmneziaWG v3.1 UDP (порт ${AWG_V3_PORT:-8443}): слушает"
        fi
    fi

    # 4. AdGuard Home
    if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet AdGuardHome 2>/dev/null; then
            ok "Служба AdGuard Home: активна (running)"
        else
            warn "Служба AdGuard Home: НЕ АКТИВНА!"
        fi
        if timeout 2 bash -c '</dev/tcp/127.0.0.1/53' 2>/dev/null || ss -ulpn 2>/dev/null | grep -q ':53 '; then
            ok "AdGuard Home DNS (порт 53): слушает"
        fi
    fi

    # 5. SSL сертификат
    local main_cert=""
    if [ "${SSL_ENGINE_CHOICE:-1}" = "1" ]; then
        main_cert="/etc/letsencrypt/live/${PRIMARY_DOMAIN:-}/fullchain.pem"
    else
        main_cert="/etc/ssl/acme/${PRIMARY_DOMAIN:-}/fullchain.pem"
    fi
    if [ -f "$main_cert" ] && command -v openssl >/dev/null 2>&1; then
        local exp_date
        exp_date=$(openssl x509 -enddate -noout -in "$main_cert" 2>/dev/null | cut -d= -f2 || true)
        local exp_epoch
        exp_epoch=$(date -d "$exp_date" +%s 2>/dev/null || echo 0)
        local now_epoch
        now_epoch=$(date +%s)
        local days_left=$(( (exp_epoch - now_epoch) / 86400 ))
        if [ "$days_left" -gt 0 ]; then
            ok "SSL-сертификат $PRIMARY_DOMAIN: действителен (осталось $days_left дн., до $exp_date)"
        else
            warn "SSL-сертификат $PRIMARY_DOMAIN: ИСТЕК ИЛИ НЕВАЛИДЕН!"
            all_ok=0
        fi
    fi

    # 6. Decoy сайт
    if [ -n "${PRIMARY_DOMAIN:-}" ] && command -v curl >/dev/null 2>&1; then
        local http_code
        http_code=$(curl -sk -o /dev/null -w "%{http_code}" --resolve "${PRIMARY_DOMAIN}:443:127.0.0.1" "https://${PRIMARY_DOMAIN}/" 2>/dev/null || echo "ERR")
        if [ "$http_code" = "200" ]; then
            ok "Веб-маска (HTTPS GET /): HTTP $http_code OK"
        else
            warn "Веб-маска (HTTPS GET /): вернула код $http_code"
        fi
    fi

    echo -e "  ${DIM}────────────────────────────────────────────────────────────${NC}"
    if [ "$all_ok" -eq 1 ]; then
        echo -e "  ${GREEN}${BOLD}✔ Все ключевые компоненты работают штатно!${NC}\n"
    else
        echo -e "  ${YELLOW}${BOLD}⚠️  Обнаружены предупреждения при проверке компонентов (см. выше).${NC}\n"
    fi
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
    doctor_check_tcp "${STEAL_PORT:-45443}" "Xray Steal-Oneself"
    doctor_check_tcp "${CLASSIC_PORT:-46443}" "Xray Classic REALITY"
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
    cat << 'EOF' > /etc/sysctl.d/99-vless-tuning.conf
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.ip_nonlocal_bind = 1
vm.swappiness = 10

# Disable IPv6 (Zero-leak policy)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

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

    # Zero-Log Policy для journald (хранение логов в RAM, защита от дисковой форензики)
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

    # TCP MSS Clamping — предотвращение PMTU Blackhole при блокировке ICMP
    # Срабатывает только на SYN-пакетах (1 раз за соединение, нулевой overhead)
    # Решает проблему зависания TCP на мобильных ISP и при прохождении через ТСПУ
    if ! iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
        iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    fi

    # Персистентность MSS Clamping через /etc/ufw/before.rules
    if [ -f /etc/ufw/before.rules ] && ! grep -q '^\*mangle' /etc/ufw/before.rules 2>/dev/null; then
        sed -i '/^\*filter/i\# TCP MSS Clamping - prevents PMTU blackhole (added by setup_mask.sh)\n*mangle\n:FORWARD ACCEPT [0:0]\n-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu\nCOMMIT\n' /etc/ufw/before.rules
    fi
}

setup_nginx_mainline() {
    export DEBIAN_FRONTEND=noninteractive
    if command -v nginx >/dev/null 2>&1 && nginx -v >/dev/null 2>&1; then
        return 0
    fi
    apt-get update -q || true
    apt-get install gnupg ca-certificates lsb-release openssl -y -q || true

    mkdir -p /usr/share/keyrings
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg --yes

    local os_id os_codename
    os_id=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
    os_codename=$(lsb_release -cs)

    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/$os_id $os_codename nginx" \
        > /etc/apt/sources.list.d/nginx.list

    cat << EOF > /etc/apt/preferences.d/99nginx
Package: nginx*
Pin: origin nginx.org
Pin-Priority: 900
EOF

    apt-get update -q || true
    apt-get install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" nginx -y -q
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
    certbot certonly --webroot -w "$WEBROOT" --expand -d "$dom" --non-interactive
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
    chmod 755 "/etc/ssl/acme/$dom" && \
    "$_ACME" --install-cert -d "$dom" \
        --key-file       "/etc/ssl/acme/$dom/privkey.pem" \
        --fullchain-file "/etc/ssl/acme/$dom/fullchain.pem" \
        --reloadcmd     "chmod 755 /etc/ssl /etc/ssl/acme /etc/ssl/acme/$dom 2>/dev/null || true; chmod 644 /etc/ssl/acme/$dom/* 2>/dev/null || true; systemctl reload nginx"
}

nginx_reload_task() {
    nginx -t && \
    systemctl unmask nginx 2>/dev/null || true && \
    systemctl enable nginx 2>/dev/null || true && \
    systemctl restart nginx
}

# =============================================================
#  ФОНОВАЯ ПРЕД-УСТАНОВКА (Zero-Wait Provisioning)
# =============================================================
BG_PREINSTALL_PID=""
PREINSTALL_COMPLETED=0

start_background_preinstall() {
    if [ "$NON_INTERACTIVE" -eq 0 ] && [ "${DEBUG_MODE:-0}" -eq 0 ]; then
        local log_file="/tmp/setup_mask_preinstall.log"
        : > "$log_file"
        rm -f /tmp/setup_mask_bg_duration_*.time 2>/dev/null || true
        {
            export DEBIAN_FRONTEND=noninteractive
            # 1. Базовые утилиты
            local _t1_start
            _t1_start=$(date +%s)
            install_prerequisites
            local _t1_end
            _t1_end=$(date +%s)
            echo $(( _t1_end - _t1_start )) > /tmp/setup_mask_bg_duration_1.time

            # 2. Тюнинг ядра
            local _t2_start
            _t2_start=$(date +%s)
            apply_sysctl_and_limits
            local _t2_end
            _t2_end=$(date +%s)
            echo $(( _t2_end - _t2_start )) > /tmp/setup_mask_bg_duration_2.time

            # 3. Nginx Mainline
            local _t3_start
            _t3_start=$(date +%s)
            setup_nginx_mainline
            local _t3_end
            _t3_end=$(date +%s)
            echo $(( _t3_end - _t3_start )) > /tmp/setup_mask_bg_duration_3.time

            # 4. Ядро 3X-UI (если ещё не установлено)
            if ! command -v x-ui >/dev/null 2>&1 && [ ! -f /etc/x-ui/x-ui.db ] && [ ! -f /usr/local/x-ui/bin/x-ui.db ]; then
                local _tx_start
                _tx_start=$(date +%s)
                curl -Ls --connect-timeout 15 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/install_3xui.sh 2>/dev/null
                printf "n\n" | bash /tmp/install_3xui.sh || true
                local _tx_end
                _tx_end=$(date +%s)
                echo $(( _tx_end - _tx_start )) > /tmp/setup_mask_bg_duration_xui.time
            fi
        } >> "$log_file" 2>&1 &
        BG_PREINSTALL_PID=$!
        echo -e "  ${CYAN}⚡ [Фоновая подготовка]${NC} ${DIM}Установка Nginx, 3X-UI и сетевого стека запущена параллельно...${NC}\n"
    fi
}

sync_background_preinstall() {
    if [ -n "${BG_PREINSTALL_PID:-}" ]; then
        local log_file="/tmp/setup_mask_preinstall.log"
        if kill -0 "$BG_PREINSTALL_PID" 2>/dev/null; then
            local spin_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
            local delay=0.08
            local i=0
            tput civis 2>/dev/null || echo -ne "\033[?25l"
            while kill -0 "$BG_PREINSTALL_PID" 2>/dev/null; do
                i=$(( (i + 1) % 10 ))
                printf "\r  ${CYAN}${spin_chars[$i]}${NC}  ${WHITE}%-54s${NC}" "Доустановка компонентов в фоне (Nginx, 3X-UI)..."
                sleep "$delay"
            done
            wait "$BG_PREINSTALL_PID"
            local exit_code=$?
            tput cnorm 2>/dev/null || echo -ne "\033[?25h"
            if [ $exit_code -eq 0 ]; then
                printf "\r  ${GREEN}${CHECK}${NC}  ${WHITE}%-54s${NC} ${GREEN}[ГОТОВО]${NC}\n" "Фоновая подготовка пакетов (Nginx, 3X-UI, BBR)"
                PREINSTALL_COMPLETED=1
            else
                printf "\r  ${RED}${CROSS}${NC}  ${WHITE}%-54s${NC} ${RED}[ОШИБКА]${NC}\n" "Фоновая подготовка пакетов"
                [ -f "$log_file" ] && tail -n 25 "$log_file" | sed 's/^/    /' || true
                die "Ошибка при фоновой установке пакетов. Подробности выше."
            fi
        else
            wait "$BG_PREINSTALL_PID"
            local exit_code=$?
            if [ $exit_code -eq 0 ]; then
                echo -e "  ${GREEN}${CHECK}${NC}  ${WHITE}Базовые пакеты (Nginx, 3X-UI, BBR) уже подготовлены в фоне${NC} ${GREEN}[ГОТОВО]${NC}"
                PREINSTALL_COMPLETED=1
            else
                echo -e "  ${RED}${CROSS}${NC}  ${WHITE}Ошибка при фоновой подготовке пакетов${NC}"
                [ -f "$log_file" ] && tail -n 25 "$log_file" | sed 's/^/    /' || true
                die "Ошибка при фоновой установке пакетов. Подробности выше."
            fi
        fi
        BG_PREINSTALL_PID=""
    fi
}

# =============================================================
#  ИНТЕРАКТИВНАЯ КОНФИГУРАЦИЯ И СЦЕНАРИИ МАРШРУТИЗАЦИИ
# =============================================================
EXPRESS_MODE=${EXPRESS_MODE:-0}
EXPERT_MODE=${EXPERT_MODE:-0}

# Проверка сохраненной контрольной точки (Resume Checkpoint)
SKIP_INTERVIEW=0
if [ "$NON_INTERACTIVE" -eq 0 ]; then
    print_mask_banner
    if [ "$LAST_COMPLETED_STEP" -gt 0 ] && [ "$LAST_COMPLETED_STEP" -lt "$TOTAL_STEPS" ]; then
        NEXT_STEP=$(( LAST_COMPLETED_STEP + 1 ))
        echo -e "  ${YELLOW}${BOLD}Обнаружена незавершенная установка!${NC}"
        echo -e "  ${DIM}Последний успешно завершенный шаг: ${WHITE}Шаг $LAST_COMPLETED_STEP из $TOTAL_STEPS (${STEP_NAMES[$LAST_COMPLETED_STEP]:-})${NC}"
        echo -e "    ${CYAN}${BOLD}[1] Продолжить с шага $NEXT_STEP (${STEP_NAMES[$NEXT_STEP]:-})${NC} (Рекомендуется)"
        echo -e "    ${YELLOW}[2] Начать установку заново (с шага 1)${NC}\n"
        read -rp "  Ваш выбор [1/2] (по умолчанию: 1): " RESUME_CHOICE </dev/tty || read -r RESUME_CHOICE || RESUME_CHOICE="1"
        RESUME_CHOICE=$(echo "${RESUME_CHOICE:-1}" | tr -d '[:space:]')
        if [ "$RESUME_CHOICE" != "2" ]; then
            RESUME_STEP="$NEXT_STEP"
            SKIP_INTERVIEW=1
            ok "Возобновление установки с шага $RESUME_STEP..."
        else
            LAST_COMPLETED_STEP=0
            RESUME_STEP=1
            record_step_completed 0
            ok "Сброс контрольной точки. Установка будет начата с первого шага."
        fi
        echo ""
    fi
else
    # В неинтерактивном режиме с переданным конфигом пропускаем интервью и возобновляем
    SKIP_INTERVIEW=1
    if [ "$LAST_COMPLETED_STEP" -gt 0 ] && [ "$LAST_COMPLETED_STEP" -lt "$TOTAL_STEPS" ]; then
        RESUME_STEP=$(( LAST_COMPLETED_STEP + 1 ))
        ok "Неинтерактивный режим: возобновление с шага $RESUME_STEP..."
    fi
fi

if [ "$SKIP_INTERVIEW" -eq 1 ]; then
    # Восстановление массивов из сохраненных скалярных параметров конфигурации
    reconstruct_arrays_from_vars
    REALITY_FALLBACK_PORT="9443"
    if [ "$SSL_ENGINE_CHOICE" = "1" ]; then
        SSL_BASE_DIR="/etc/letsencrypt/live"
    else
        SSL_BASE_DIR="/etc/ssl/acme"
    fi
else
    if [ "$NON_INTERACTIVE" -eq 0 ]; then
        start_background_preinstall
        START_AT_REVIEW=0
        if [ -n "${PRIMARY_DOMAIN:-}" ]; then
            echo
            echo -e "  ${YELLOW}${BOLD}Обнаружена сохраненная конфигурация предыдущей сессии!${NC}"
            echo -e "    ${DIM}• Домен:${NC} ${GREEN}${PRIMARY_DOMAIN}${NC}  ${DIM}• Префикс сервера:${NC} ${WHITE}${SERVER_PREFIX:-Server}${NC}"
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
                    EXPERT_MODE=1
                    START_AT_REVIEW=0
                    ok "Пошаговый режим: сохраненные значения подставлены по умолчанию."
                    ;;
                3)
                    PRIMARY_DOMAIN=""
                    SERVER_PREFIX=""
                    ADD_WWW=""
                    ENABLE_STEAL=""
                    ENABLE_CLASSIC=""
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

        if [ -z "${PRIMARY_DOMAIN:-}" ] && [ "$EXPRESS_MODE" -eq 0 ] && [ "$EXPERT_MODE" -eq 0 ]; then
            echo -e "  ${WHITE}${BOLD}Выберите режим настройки:${NC}\n"
            echo -e "    ${CYAN}${BOLD}[1] Экспресс-установка (Рекомендуется)${NC} — Настройка в 2 вопроса"
            echo -e "        ${DIM}• Ввод только домена и email для Let's Encrypt.${NC}"
            echo -e "        ${DIM}• Автоматический выбор лучших протоколов (Steal-Oneself, Classic REALITY, xHTTP).${NC}"
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

if [ "$EXPRESS_MODE" -eq 1 ]; then
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
    
    # Автоматические пресеты для Экспресс-режима
    ADD_WWW="n"
    ENABLE_STEAL="y"
    STEAL_PORT="45443"
    STEAL_DOMAINS=("cdn.$PRIMARY_DOMAIN")
    ENABLE_CLASSIC="y"
    CLASSIC_PORT="46443"
    CLASSIC_SNI_LIST=("gateway.icloud.com")
    PANEL_PORT="${PANEL_PORT:-10443}"
    ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 12)}"
    SERVER_PREFIX="${SERVER_PREFIX:-Server}"
    if [ -n "${PANEL_PATH:-}" ]; then
        RAW_PATH="${PANEL_PATH#/}"
        RAW_PATH="${RAW_PATH%/}"
        PANEL_PATH="/${RAW_PATH}/"
    else
        RAW_PATH="panel-$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
        PANEL_PATH="/${RAW_PATH}/"
    fi
    SUB_PORT="55443"
    RAW_SUB_PATH="sub-$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
    SUB_PATH="/${RAW_SUB_PATH}/"
    SUB_JSON_PATH="${SUB_PATH}json/"
    SUB_CLASH_PATH="${SUB_PATH}clash/"
    XHTTP_STREAM_PORT="50443"
    RAW_XHTTP_STREAM_PATH="xhttp-stream"
    XHTTP_STREAM_PATH="/${RAW_XHTTP_STREAM_PATH}/"
    ENABLE_HY2="1"
    HY2_PORT="443"
    HY2_DOMAIN="$PRIMARY_DOMAIN"
    HY2_PORT_HOPPING="${HY2_PORT_HOPPING:-n}"
    HY2_PORT_HOPPING_RANGE="${HY2_PORT_HOPPING_RANGE:-20000:50000}"
    ENABLE_AWG_V3="1"
    AWG_V3_PORT="8443"
    ENABLE_AWG_V2="1"
    AWG_V2_PORT="8444"
    DECOY_MODE="1"
    SSL_ENGINE_CHOICE="1"
    AUTO_SETUP_3XUI="y"
    ENABLE_NODE_TOKEN="${ENABLE_NODE_TOKEN:-n}"
    NODE_TOKEN_NAME="${NODE_TOKEN_NAME:-}"
    NODE_TOKEN="${NODE_TOKEN:-}"
    ENABLE_WARP="${ENABLE_WARP:-y}"
    WARP_LICENSE_KEY="${WARP_LICENSE_KEY:-}"
    ENABLE_AGH="${ENABLE_AGH:-y}"
    AGH_MODE="${AGH_MODE:-1}"
    AGH_DOMAIN=""
    AGH_USER="${AGH_USER:-admin}"
    DEFAULT_AG_PASS="AgHome_$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 8 || echo 'Pass1234')"
    AGH_PASS="${AGH_PASS:-$DEFAULT_AG_PASS}"
    AGH_CLIENT_ID="${AGH_CLIENT_ID:-home-router}"
    AGH_XRAY_DNS="${AGH_XRAY_DNS:-y}"
    STEAL_ENABLED=1
    CLASSIC_ENABLED=1
    
    ALL_DOMAINS=("$PRIMARY_DOMAIN")
    declare -A DOMAIN_TO_PORT=()
    declare -A EXT_SNI_TO_PORT=()
    STEAL_PORTS_LIST=("$STEAL_PORT")
    CLASSIC_PORTS_LIST=("$CLASSIC_PORT")
    ALL_REALITY_PORTS=("$STEAL_PORT" "$CLASSIC_PORT")
    REALITY_FALLBACK_PORT="9443"
    
    ALL_DOMAINS+=("cdn.$PRIMARY_DOMAIN")
    DOMAIN_TO_PORT["cdn.$PRIMARY_DOMAIN"]="$STEAL_PORT"
    
    ALL_EXT_SNIS=("gateway.icloud.com")
    EXT_SNI_TO_PORT["gateway.icloud.com"]="$CLASSIC_PORT"
    
    echo -e "  ${GREEN}${CHECK} Экспресс-параметры применены:${NC}"
    echo -e "    ${DIM}• Домен:${NC}          ${WHITE}${BOLD}$PRIMARY_DOMAIN${NC}"
    echo -e "    ${DIM}• Steal-Oneself:${NC}  ${WHITE}cdn.$PRIMARY_DOMAIN -> 127.0.0.1:$STEAL_PORT${NC}"
    echo -e "    ${DIM}• Classic REALITY:${NC}${WHITE}gateway.icloud.com -> 127.0.0.1:$CLASSIC_PORT${NC}"
    echo -e "    ${DIM}• VLESS xHTTP:${NC}    ${WHITE}$XHTTP_STREAM_PATH -> 127.0.0.1:$XHTTP_STREAM_PORT${NC}"
    echo -e "    ${DIM}• UDP Стек:${NC}       ${WHITE}Hysteria 2 (:443), AWG v3 (:8443), AWG v2 (:8444)${NC}"
    echo -e "    ${DIM}• Cloudflare WARP:${NC} ${WHITE}Активирован (Google, Gemini, AI / YouTube direct)${NC}"
    echo -e "    ${DIM}• Веб-маска:${NC}      ${WHITE}DataSphere Analytics${NC}"
    echo ""
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
    'gateway.icloud.com',
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
        [ -n "${PRIMARY_DOMAIN:-}" ] || die "Ошибка: PRIMARY_DOMAIN не задан в конфигурации или аргументах!"
        [[ "$PRIMARY_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || die "Некорректный формат доменного имени: $PRIMARY_DOMAIN"
        ok "Основной домен (из конфигурации): $PRIMARY_DOMAIN"

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
            local classic_sni_list="${CLASSIC_SNI:-gateway.icloud.com}"
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
        if [ -n "${PANEL_PATH:-}" ]; then
            RAW_PATH="${PANEL_PATH#/}"; RAW_PATH="${RAW_PATH%/}"
        elif [ -z "${RAW_PATH:-}" ]; then
            RAW_PATH="panel-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "3xui${RANDOM}")"
        fi
        RAW_PATH="${RAW_PATH#/}"; RAW_PATH="${RAW_PATH%/}"
        validate_path_segment "$RAW_PATH" "URI панели"
        PANEL_PATH="/${RAW_PATH#/}"; PANEL_PATH="${PANEL_PATH%/}/"

        SUB_PORT="${SUB_PORT:-55443}"
        RAW_SUB_PATH="${RAW_SUB_PATH:-${SUB_PATH:-sub-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "sub${RANDOM}")}}"
        RAW_SUB_PATH="${RAW_SUB_PATH#/}"; RAW_SUB_PATH="${RAW_SUB_PATH%/}"
        validate_path_segment "$RAW_SUB_PATH" "URI подписок"
        SUB_PATH="/${RAW_SUB_PATH#/}"; SUB_PATH="${SUB_PATH%/}/"
        SUB_JSON_PATH="${SUB_PATH}json/"
        SUB_CLASH_PATH="${SUB_PATH}clash/"

        XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
        RAW_XHTTP_STREAM_PATH="${RAW_XHTTP_STREAM_PATH:-${XHTTP_STREAM_PATH:-vless-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "xhttp${RANDOM}")}}"
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

        # AdGuard Home
        if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
            ENABLE_AGH=1
            AGH_MODE="${AGH_MODE:-1}"
            [ "$AGH_MODE" = "2" ] && AGH_DOMAIN="${AGH_DOMAIN:-dns.$PRIMARY_DOMAIN}" || AGH_DOMAIN=""
            AGH_USER="${AGH_USER:-admin}"
            AGH_PASS="${AGH_PASS:-AgHome_$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 8 || echo 'Pass1234')}"
            AGH_CLIENT_ID="${AGH_CLIENT_ID:-home-router}"
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
        echo -e "${YELLOW}━━━ Шаг 2/13: Настройка VLESS Steal-Oneself REALITY ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Режим REALITY, маскирующийся под ${BOLD}собственный поддомен${NC} (напр. cdn.$PRIMARY_DOMAIN)."
            echo -e "     ${GREEN}Преимущество:${NC} Трафик выглядит как обычный HTTPS к вашему сайту. Полный"
            echo -e "     иммунитет к блокировкам чужих SNI со стороны систем DPI / ТСПУ."
            echo
        fi

        prompt_yes_no "Включить Steal-Oneself REALITY?" "${ENABLE_STEAL:-y}" ENABLE_STEAL || return $?

        if is_true "${ENABLE_STEAL:-y}"; then
            STEAL_ENABLED=1
            local old_steal_dom="${STEAL_DOMAINS[0]:-${STEAL_DOMAINS_STR:-cdn.$PRIMARY_DOMAIN}}"
            local old_steal_port="${STEAL_PORTS_LIST[0]:-${STEAL_PORT:-45443}}"
            STEAL_PORTS_LIST=()
            STEAL_DOMAINS=()

            local port_input=""
            prompt_default "  Локальный порт Xray для Steal-Oneself" "$old_steal_port" port_input || return $?
            STEAL_PORT="$port_input"
            if [[ ! "$STEAL_PORT" =~ ^[0-9]+$ ]] || [ "$STEAL_PORT" -le 0 ] || [ "$STEAL_PORT" -gt 65535 ]; then
                warn "  Некорректный номер порта. Установлен порт по умолчанию: 45443."
                STEAL_PORT="45443"
            fi
            STEAL_PORTS_LIST+=("$STEAL_PORT")

            local s_dom_in=""
            prompt_default "  Домен/поддомен для Steal-Oneself на порту $STEAL_PORT" "$old_steal_dom" s_dom_in || return $?
            s_dom_in=$(echo "${s_dom_in:-$old_steal_dom}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

            if [[ ! "$s_dom_in" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
                warn "  Некорректный синтаксис домена '$s_dom_in'. Использован $old_steal_dom."
                s_dom_in="$old_steal_dom"
            fi

            STEAL_DOMAINS=("$s_dom_in")
            DOMAIN_TO_PORT["$s_dom_in"]="$STEAL_PORT"
            ok "  Домен $s_dom_in привязан к инбаунд-порту $STEAL_PORT"

            echo ""
            [ "${SHOW_TIPS:-y}" = "y" ] && echo -e "  ${CYAN}[i]${NC} ${DIM}Одного инбаунда Steal-Oneself достаточно для всех ваших устройств.${NC}"
            local add_more=""
            prompt_yes_no "  Создать еще одно изолированное подключение (на другом порту)?" "n" add_more || return $?
            if [[ "${add_more,,}" == "y" ]]; then
                local extra_port="" extra_dom=""
                prompt_default "    Второй порт Steal-Oneself" "45444" extra_port || return $?
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
            log "Сценарий Steal-Oneself REALITY отключен."
        fi

        rebuild_all_domains
        sync_reality_ports
        return 0
    }

    q_step_classic() {
        echo
        echo -e "${YELLOW}━━━ Шаг 3/13: Настройка VLESS Classic External REALITY ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Режим REALITY, маскирующийся под ${BOLD}известные зарубежные сервисы${NC}."
            echo -e "     ${GREEN}Преимущество:${NC} Даже если ваш домен попадет под подозрение, этот инбаунд продолжит"
            echo -e "     работать, используя валидный TLS 1.3 с серверов Apple, Microsoft, Google или Samsung."
            echo
        fi

        prompt_yes_no "Включить Classic External REALITY?" "${ENABLE_CLASSIC:-y}" ENABLE_CLASSIC || return $?

        if [[ "${ENABLE_CLASSIC,,}" == "y" || "${ENABLE_CLASSIC:-}" == "1" ]]; then
            CLASSIC_ENABLED=1
            CLASSIC_PORTS_LIST=()
            EXT_SNI_LIST=()

            local port_input=""
            prompt_default "  Локальный порт Xray для Classic REALITY" "${CLASSIC_PORT:-46443}" port_input || return $?
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
                scanned_snis=("gateway.icloud.com" "dl.google.com" "www.apple.com" "www.samsung.com" "www.nvidia.com" "www.microsoft.com")
                scanned_lats=("fast" "fast" "fast" "fast" "fast" "fast")
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
            log "Сценарий Classic External REALITY отключен."
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

            local rand_p_path="panel-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "3xui${RANDOM}")"
            local r_path="${RAW_PATH:-${PANEL_PATH:-$rand_p_path}}"
            r_path="${r_path#/}"; r_path="${r_path%/}"
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
            SUB_JSON_PATH="${SUB_PATH}json/"
            SUB_CLASH_PATH="${SUB_PATH}clash/"

            prompt_default "  Внутренний порт инбаунда VLESS xHTTP" "${XHTTP_STREAM_PORT:-50443}" XHTTP_STREAM_PORT || return $?
            local rand_x_path="vless-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "xhttp${RANDOM}")"
            local r_xhttp="${RAW_XHTTP_STREAM_PATH:-${XHTTP_STREAM_PATH:-$rand_x_path}}"
            r_xhttp="${r_xhttp#/}"; r_xhttp="${r_xhttp%/}"
            prompt_default "  URI-путь для xHTTP Stream-One" "$r_xhttp" RAW_XHTTP_STREAM_PATH || return $?
            validate_path_segment "$RAW_XHTTP_STREAM_PATH" "URI xHTTP"
            XHTTP_STREAM_PATH="/${RAW_XHTTP_STREAM_PATH#/}"; XHTTP_STREAM_PATH="${XHTTP_STREAM_PATH%/}/"
        else
            PANEL_PORT="${PANEL_PORT:-10443}"
            ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
            [ -n "${ADMIN_PASSWORD:-}" ] || ADMIN_PASSWORD="$(head /dev/urandom 2>/dev/null | tr -dc A-Za-z0-9 | head -c 12 || echo "Admin1234567")"

            if [ -n "${PANEL_PATH:-}" ]; then
                RAW_PATH="${PANEL_PATH#/}"; RAW_PATH="${RAW_PATH%/}"
            elif [ -z "${RAW_PATH:-}" ]; then
                RAW_PATH="panel-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "3xui${RANDOM}")"
            fi
            RAW_PATH="${RAW_PATH#/}"; RAW_PATH="${RAW_PATH%/}"
            PANEL_PATH="/${RAW_PATH#/}"; PANEL_PATH="${PANEL_PATH%/}/"

            SUB_PORT="${SUB_PORT:-55443}"
            [ -n "${RAW_SUB_PATH:-}" ] || RAW_SUB_PATH="sub-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "sub${RANDOM}")"
            RAW_SUB_PATH="${RAW_SUB_PATH#/}"; RAW_SUB_PATH="${RAW_SUB_PATH%/}"
            SUB_PATH="/${RAW_SUB_PATH#/}"; SUB_PATH="${SUB_PATH%/}/"
            SUB_JSON_PATH="${SUB_PATH}json/"
            SUB_CLASH_PATH="${SUB_PATH}clash/"

            XHTTP_STREAM_PORT="${XHTTP_STREAM_PORT:-50443}"
            [ -n "${RAW_XHTTP_STREAM_PATH:-}" ] || RAW_XHTTP_STREAM_PATH="vless-$(head /dev/urandom 2>/dev/null | tr -dc a-z0-9 | head -c 8 || echo "xhttp${RANDOM}")"
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

    q_step_hy2() {
        echo
        echo -e "${YELLOW}━━━ Шаг 5/13: Настройка протокола Hysteria 2 (UDP) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Сверхбыстрый протокол на базе QUIC/UDP с алгоритмом Brutal."
            echo -e "     Обеспечивает максимальную скорость стриминга и загрузки даже на плохом"
            echo -e "     мобильном интернете (LTE/5G) с потерей пакетов до 20-30%."
            echo
        fi

        prompt_yes_no "Установить и настроить Hysteria 2?" "${ENABLE_HY2:-y}" ENABLE_HY2 || return $?

        if [[ "${ENABLE_HY2,,}" == "y" || "${ENABLE_HY2:-}" == "1" ]]; then
            ENABLE_HY2=1
            prompt_default "  Внешний UDP-порт для Hysteria 2" "${HY2_PORT:-443}" HY2_PORT || return $?
            prompt_default "  Домен/поддомен для подключения Hysteria 2" "${HY2_DOMAIN:-$PRIMARY_DOMAIN}" HY2_DOMAIN || return $?
            HY2_DOMAIN=$(echo "$HY2_DOMAIN" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

            [ "${SHOW_TIPS:-y}" = "y" ] && echo -e "  ${DIM}• Port Hopping позволяет клиентам скакать по портам для обхода шейпинга операторов,${NC}"
            [ "${SHOW_TIPS:-y}" = "y" ] && echo -e "    ${DIM}но делает диапазон 20000-50000 видимым в сетевых сканерах (Censys/Shodan).${NC}"
            prompt_yes_no "  Включить Port Hopping для Hysteria 2 (UDP 20000:50000)?" "${HY2_PORT_HOPPING:-n}" HY2_PORT_HOPPING || return $?
            if [[ "${HY2_PORT_HOPPING,,}" == "y" || "${HY2_PORT_HOPPING:-}" == "1" ]]; then
                HY2_PORT_HOPPING="y"
                prompt_default "  Диапазон портов Port Hopping" "${HY2_PORT_HOPPING_RANGE:-20000:50000}" HY2_PORT_HOPPING_RANGE || return $?
                ok "Port Hopping активирован для диапазона UDP ${HY2_PORT_HOPPING_RANGE}."
            else
                HY2_PORT_HOPPING="n"
                log "Port Hopping отключен (чистый стелс на едином порту ${HY2_PORT}/udp)."
            fi
            ok "Hysteria 2 активирована на порту ${HY2_PORT}/udp (домен: ${HY2_DOMAIN})"
        else
            ENABLE_HY2=0
            HY2_PORT=""
            HY2_DOMAIN=""
            HY2_PORT_HOPPING="n"
            log "Hysteria 2 отключена."
        fi

        rebuild_all_domains
        return 0
    }

    q_step_awg_v3() {
        echo
        echo -e "${YELLOW}━━━ Шаг 6/13: Настройка протокола AmneziaWG v3.1 ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Усовершенствованный WireGuard с обфускацией пакетов (Junk/Init/Resp)."
            echo -e "     Специально разработан для обхода ТСПУ/DPI в России. Трафик выглядит как случайный шум."
            echo
        fi

        prompt_yes_no "Установить и настроить AmneziaWG v3.1?" "${ENABLE_AWG_V3:-y}" ENABLE_AWG_V3 || return $?
        if [[ "${ENABLE_AWG_V3,,}" == "y" || "${ENABLE_AWG_V3:-}" == "1" ]]; then
            ENABLE_AWG_V3=1
            prompt_default "  Внешний UDP-порт для AmneziaWG v3.1" "${AWG_V3_PORT:-8443}" AWG_V3_PORT || return $?
            ok "AmneziaWG v3.1 активирована на порту ${AWG_V3_PORT}/udp"
        else
            ENABLE_AWG_V3=0
            AWG_V3_PORT=""
            log "AmneziaWG v3.1 отключена."
        fi
        return 0
    }

    q_step_awg_v2() {
        echo
        echo -e "${YELLOW}━━━ Шаг 7/13: Настройка протокола AmneziaWG v2.0 / Legacy ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Классическая версия AmneziaWG (заголовки H1-H4)."
            echo -e "     ${GREEN}Зачем нужна:${NC} Для совместимости со старыми роутерами (Keenetic, OpenWrt)"
            echo -e "     и клиентами, которые еще не обновились до версии 3.1."
            echo
        fi

        prompt_yes_no "Установить и настроить AmneziaWG v2.0 / Legacy?" "${ENABLE_AWG_V2:-y}" ENABLE_AWG_V2 || return $?
        if [[ "${ENABLE_AWG_V2,,}" == "y" || "${ENABLE_AWG_V2:-}" == "1" ]]; then
            ENABLE_AWG_V2=1
            prompt_default "  Внешний UDP-порт для AmneziaWG v2.0" "${AWG_V2_PORT:-8444}" AWG_V2_PORT || return $?
            ok "AmneziaWG v2.0 активирована на порту ${AWG_V2_PORT}/udp"
        else
            ENABLE_AWG_V2=0
            AWG_V2_PORT=""
            log "AmneziaWG v2.0 отключена."
        fi
        return 0
    }

    q_step_agh() {
        echo
        echo -e "${YELLOW}━━━ Шаг 8/13: Настройка приватного AdGuard Home DoH + Split-DNS ━━━${NC}"
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
            prompt_default "  Секретный ClientID токен для роутера" "${AGH_CLIENT_ID:-home-router}" AGH_CLIENT_ID || return $?
            prompt_yes_no "  Использовать AdGuard Home как DNS для VPN-клиентов (Xray)?" "${AGH_XRAY_DNS:-y}" AGH_XRAY_DNS || return $?
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
        echo -e "${YELLOW}━━━ Шаг 9/13: Выбор темы для сайта-маскировки (Decoy Site) ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Веб-сайт, который отображается в браузере при обращении к вашему домену."
            echo -e "     Защищает сервер от выявления цензорами, активными сканерами и сетевыми ботами."
            echo
            echo -e "  ${BOLD}Доступные варианты маскировки:${NC}"
            echo -e "    ${GREEN}[1] DataSphere Analytics (Рекомендуется)${NC}"
            echo -e "        ${DIM}• Корпоративный портал распределенной аналитики данных${NC}"
            echo -e "        ${DIM}• Интерактивная 3D-сфера узлов, Anycast-телеметрия потока и Web CLI${NC}"
            echo -e "        ${DIM}• Документация API, статус сервисов и строгий Zero-Inline CSP${NC}"
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
        echo -e "${YELLOW}━━━ Шаг 10/13: Реестр SSL-сертификатов и дополнительные домены ━━━${NC}"
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
        echo -e "${YELLOW}━━━ Шаг 11/13: Выбор метода выпуска SSL-сертификатов ━━━${NC}"
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
        echo -e "${YELLOW}━━━ Шаг 12/13: Автоматическая настройка базы данных панели 3X-UI ━━━${NC}"
        if [[ "${SHOW_TIPS,,}" == "y" || "${SHOW_TIPS:-}" == "1" ]]; then
            echo -e "  ${CYAN}💡 Что это:${NC} Автоматическое создание всех инбаундов (Steal-Oneself, Classic REALITY, xHTTP)"
            echo -e "     в базе данных панели 3X-UI, а также настройка секретных путей и подписок."
            echo -e "     Вам не придется добавлять инбаунды вручную через браузер."
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

            prompt_yes_no "Создать API-токен для подключения сервера как узла (3X-UI Node)?" "${ENABLE_NODE_TOKEN:-n}" ENABLE_NODE_TOKEN || return $?
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
        echo -e "${YELLOW}━━━ Шаг 13/13: Исходящий туннель Cloudflare WARP ━━━${NC}"
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
        echo -e "  ${CYAN}[2]${NC} ${BOLD}Steal-Oneself:${NC}        $steal_status"

        local classic_status="${RED}Отключен${NC}"
        if is_true "${CLASSIC_ENABLED:-0}"; then
            classic_status="${GREEN}Включен${NC} (SNI: ${WHITE}${EXT_SNI_LIST[*]}${NC} -> 127.0.0.1:${CLASSIC_PORTS_LIST[*]})"
        fi
        echo -e "  ${CYAN}[3]${NC} ${BOLD}Classic REALITY:${NC}      $classic_status"

        echo -e "  ${CYAN}[4]${NC} ${BOLD}Внутренние порты:${NC}     Панель :${WHITE}$PANEL_PORT${NC} (${DIM}$PANEL_PATH${NC}), Подписки :${WHITE}$SUB_PORT${NC} (${DIM}$SUB_PATH, Clash: $SUB_CLASH_PATH${NC}), xHTTP :${WHITE}$XHTTP_STREAM_PORT${NC}"
        echo -e "      ${DIM}Доступ в 3X-UI:${NC}       Логин: ${WHITE}$ADMIN_USERNAME${NC}, Пароль: ${YELLOW}$ADMIN_PASSWORD${NC}"

        local hy2_status="${RED}Отключена${NC}"
        if is_true "${ENABLE_HY2:-0}"; then
            local hop_str=""
            [ "$HY2_PORT_HOPPING" = "y" ] && hop_str=" + Hopping $HY2_PORT_HOPPING_RANGE"
            hy2_status="${GREEN}Включена${NC} (:${HY2_PORT}/udp, ${HY2_DOMAIN}${hop_str})"
        fi
        echo -e "  ${CYAN}[5]${NC} ${BOLD}Hysteria 2 (UDP):${NC}     $hy2_status"

        local awg3_status="${RED}Отключен${NC}"
        is_true "${ENABLE_AWG_V3:-0}" && awg3_status="${GREEN}Включен${NC} (:${AWG_V3_PORT}/udp)"
        echo -e "  ${CYAN}[6]${NC} ${BOLD}AmneziaWG v3.1:${NC}       $awg3_status"

        local awg2_status="${RED}Отключен${NC}"
        is_true "${ENABLE_AWG_V2:-0}" && awg2_status="${GREEN}Включен${NC} (:${AWG_V2_PORT}/udp)"
        echo -e "  ${CYAN}[7]${NC} ${BOLD}AmneziaWG v2.0:${NC}       $awg2_status"

        local agh_status="${RED}Отключен${NC}"
        if is_true "${ENABLE_AGH:-0}"; then
            local m_desc="Основной домен"
            [ "$AGH_MODE" = "2" ] && m_desc="Поддомен $AGH_DOMAIN"
            agh_status="${GREEN}Включен${NC} (Режим: $m_desc, ClientID: $AGH_CLIENT_ID)"
        fi
        echo -e "  ${CYAN}[8]${NC} ${BOLD}AdGuard Home DoH:${NC}     $agh_status"

        local decoy_name="DataSphere Analytics"
        [ "$DECOY_MODE" = "2" ] && decoy_name="CosmosCloud NextGen"
        [ "$DECOY_MODE" = "3" ] && decoy_name="Стандартная заглушка Nginx"
        echo -e "  ${CYAN}[9]${NC} ${BOLD}Тема маскировки:${NC}      ${WHITE}$decoy_name${NC}"

        echo -e "  ${CYAN}[10]${NC} ${BOLD}SSL-домены (${#ALL_DOMAINS[@]}):${NC}   ${WHITE}${ALL_DOMAINS[*]}${NC}"

        local ssl_name="Certbot (HTTP-01)"
        [ "$SSL_ENGINE_CHOICE" = "2" ] && ssl_name="acme.sh + Cloudflare DNS-01"
        echo -e "  ${CYAN}[11]${NC} ${BOLD}Метод выпуска SSL:${NC}    ${WHITE}$ssl_name${NC}"

        local auto_3xui_str="${GREEN}Да${NC}"
        is_true "${AUTO_SETUP_3XUI:-y}" || auto_3xui_str="${RED}Нет${NC}"
        if is_true "${ENABLE_NODE_TOKEN:-n}"; then
            auto_3xui_str="${auto_3xui_str} ${DIM}(+ Node Token: ${WHITE}${NODE_TOKEN_NAME}${DIM})${NC}"
        fi
        echo -e "  ${CYAN}[12]${NC} ${BOLD}3X-UI автонастройка:${NC}  $auto_3xui_str"

        local warp_status="${RED}Отключен${NC}"
        is_true "${ENABLE_WARP:-n}" && warp_status="${GREEN}Включен${NC} (WireGuard MTU: 1280)"
        echo -e "  ${CYAN}[13]${NC} ${BOLD}Cloudflare WARP:${NC}      $warp_status"

        echo
        echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════${NC}"
        echo -e "  ${GREEN}[Enter]${NC} или ${GREEN}[y]${NC}  ${BOLD}Начать установку с выбранными параметрами${NC}"
        echo -e "  ${CYAN}[1 - 13]${NC}        ${BOLD}Изменить соответствующий раздел конфигурации${NC}"
        echo -e "  ${RED}[q]${NC}             ${BOLD}Отмена и выход${NC}"
        echo -e "${YELLOW}════════════════════════════════════════════════════════════════════════════════${NC}"
        echo

        while true; do
            local choice=""
            echo -ne "  ${WHITE}${ARROW} Ваш выбор [${GREEN}Enter = начать${WHITE}]: ${NC}"
            read -r choice </dev/tty || read -r choice || true
            choice=$(echo "${choice:-}" | tr -d '[:space:]')

            if [ -z "$choice" ] || [[ "${choice,,}" == "y" ]] || [[ "${choice,,}" == "yes" ]]; then
                save_session_state "$SAVED_CONFIG_FILE" >/dev/null 2>&1 || true
                return 0
            fi

            if [[ "${choice,,}" == "q" || "${choice,,}" == "quit" || "${choice,,}" == "exit" ]]; then
                die "Установка отменена пользователем."
            fi

            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le 13 ]; then
                return $((100 + choice))
            fi

            warn "  Некорректный ввод. Нажмите Enter для старта, номер [1-13] для изменения или 'q' для выхода."
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
            CURRENT_STEP=14
            EDITING_FROM_REVIEW=0
        else
            CURRENT_STEP=1
            EDITING_FROM_REVIEW=0
        fi
        TOTAL_STEPS=14

        while [ "$CURRENT_STEP" -le "$TOTAL_STEPS" ]; do
            res=0
            case "$CURRENT_STEP" in
                1) q_step_domain || res=$? ;;
                2) q_step_steal || res=$? ;;
                3) q_step_classic || res=$? ;;
                4) q_step_ports || res=$? ;;
                5) q_step_hy2 || res=$? ;;
                6) q_step_awg_v3 || res=$? ;;
                7) q_step_awg_v2 || res=$? ;;
                8) q_step_agh || res=$? ;;
                9) q_step_decoy || res=$? ;;
                10) q_step_ssl_domains || res=$? ;;
                11) q_step_ssl_engine || res=$? ;;
                12) q_step_3xui_auto || res=$? ;;
                13) q_step_warp || res=$? ;;
                14) q_step_review || res=$? ;;
            esac

            if [ "$res" -eq 10 ]; then
                # Запрос перехода назад
                if [ "$EDITING_FROM_REVIEW" -eq 1 ]; then
                    CURRENT_STEP=14
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
            elif [ "$res" -ge 101 ] && [ "$res" -le 113 ]; then
                # Переход к конкретному шагу из экрана Review
                CURRENT_STEP=$((res - 100))
                EDITING_FROM_REVIEW=1
            elif [ "$res" -eq 0 ]; then
                if [ "$CURRENT_STEP" -eq 14 ]; then
                    break
                elif [ "$EDITING_FROM_REVIEW" -eq 1 ]; then
                    CURRENT_STEP=14
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

# Определение системного каталога для хранения SSL
if [ "$SSL_ENGINE_CHOICE" = "1" ]; then
    SSL_BASE_DIR="/etc/letsencrypt/live"
else
    SSL_BASE_DIR="/etc/ssl/acme"
fi

# Проверка DNS-записей
log "Проверка A-записей для всех собственных доменов..."
WAN_IP=$(curl -s4 --connect-timeout 4 icanhazip.com || curl -s4 --connect-timeout 4 api.ipify.org || curl -s4 --connect-timeout 4 ifconfig.me || echo "")
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

# Сохраняем состояние сессии в файл конфигурации для защиты от обрыва SSH или повторного вызова
save_session_state "$SAVED_CONFIG_FILE"

# =============================================================
#  ФАЗА УСТАНОВКИ И РАЗВЕРТЫВАНИЯ СИСТЕМЫ
# =============================================================
if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
    TOTAL_STEPS=8
else
    TOTAL_STEPS=7
fi

# Ожидание фоновой пред-установки (если была запущена параллельно с опросом)
sync_background_preinstall

# --- Шаг 1: Системные зависимости и утилиты ---
if ! should_skip_step 1; then
    step_begin 1
    if [ "$PREINSTALL_COMPLETED" -eq 1 ]; then
        ok "Базовые утилиты (curl, socat, dig, ufw) установлены [В фоне]"
    else
        run_with_spinner "Проверка и установка базовых утилит (curl, socat, dig, ufw)" install_prerequisites || die "Ошибка установки базовых утилит."
    fi
    step_finish 1
fi

# --- Шаг 2: Тюнинг ядра Linux (TCP BBR & UDP Buffers) ---
if ! should_skip_step 2; then
    step_begin 2
    if [ "$PREINSTALL_COMPLETED" -eq 1 ]; then
        ok "Системные параметры BBR и лимиты дескрипторов применены [В фоне]"
    else
        run_with_spinner "Применение системных параметров BBR и лимитов дескрипторов" apply_sysctl_and_limits || die "Ошибка применения сетевого тюнинга."
    fi
    step_finish 2
fi

# --- Шаг 3: Установка Nginx Mainline ---
if ! should_skip_step 3; then
    step_begin 3
    if [ "$PREINSTALL_COMPLETED" -eq 1 ]; then
        ok "Репозиторий nginx.org подключен, Nginx Mainline установлен [В фоне]"
    else
        run_with_spinner "Подключение репозитория nginx.org и установка Nginx" setup_nginx_mainline || die "Ошибка установки Nginx Mainline."
    fi
    step_finish 3
fi

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
        nginx -t
        die "Ошибка синтаксиса начальной конфигурации Nginx."
    fi
    systemctl restart nginx >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1
fi

# =============================================================
#  ВЫПУСК SSL-СЕРТИФИКАТОВ (CERTBOT ИЛИ ACME.SH)
# =============================================================
if ! should_skip_step 4; then
    step_begin 4

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
            if run_with_spinner "Выпуск SSL для домена $dom (HTTP-01)" obtain_cert "$dom"; then
                :
            else
                warn "Не удалось выпустить сертификат для $dom."
                if [ "$dom" = "$PRIMARY_DOMAIN" ]; then
                    die "Критическая ошибка: Выпуск сертификата для Главного домена $PRIMARY_DOMAIN провален."
                fi
            fi
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
            if run_with_spinner "Выпуск SSL для домена $dom через Cloudflare DNS-01" obtain_cf_cert "$dom"; then
                :
            else
                warn "Ошибка при выпуске сертификата для $dom."
                if [ "$dom" = "$PRIMARY_DOMAIN" ]; then
                    die "Критическая ошибка: Выпуск сертификата для Главного домена $PRIMARY_DOMAIN провален."
                fi
            fi
        done
    fi

    # Настройка строгих прав доступа на каталоги SSL для чтения Nginx (Zero-Leak)
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
        chmod 755 /etc/ssl /etc/ssl/acme 2>/dev/null || true
        for dom in "${ALL_DOMAINS[@]}"; do
            if [ -d "/etc/ssl/acme/$dom" ]; then
                chmod 755 "/etc/ssl/acme/$dom" 2>/dev/null || true
                chmod 644 /etc/ssl/acme/"$dom"/*.pem 2>/dev/null || true
                chmod 600 /etc/ssl/acme/"$dom"/privkey*.pem 2>/dev/null || true
            fi
        done
    fi

    step_finish 4
fi

# =============================================================
#  ГЕНЕРАЦИЯ ВЫБРАННОЙ ВЕБ-МАСКИ
# =============================================================
if ! should_skip_step 5; then
    step_begin 5
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
                addLog("Шифрование сессий: ML-KEM-768 + X25519 (RFC 8446) | Zero-Knowledge");
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
                <p>Высоконагруженная инфраструктура с аппаратной изоляцией памяти Zero-Copy, постквантовым обменом ключами ML-KEM-768 и магистральной Anycast-маршрутизацией.</p>
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
    step_finish 5
fi

# =============================================================
#  ШАГ 6: ПОЛНАЯ КОНФИГУРАЦИЯ NGINX И ПЕРЕЗАПУСК СЛУЖБ
# =============================================================
if ! should_skip_step 6; then
    step_begin 6
    log "Сборка конфигурации Nginx Mainline (Stream L4 + HTTP/2 Upstream Engine)..."

    # Резервное копирование существующих конфигураций Nginx перед перезаписью
    backup_nginx_configs

    rm -rf /etc/nginx/sites-enabled/* \
           /etc/nginx/sites-available/* \
           /etc/nginx/conf.d/* \
           /etc/nginx/stream.d/*

    # 1. Глобальный файл конфигурации /etc/nginx/nginx.conf
    cat << EOF > /etc/nginx/nginx.conf
user $NGINX_USER;
worker_processes auto;
pid /run/nginx.pid;
worker_rlimit_nofile 524288;

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
    http2_recv_buffer_size 16m;
    http2_max_concurrent_streams 512;

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
        ~^1:[01]:/dns-query 0;
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
    else
        STREAM_MAP_RULES+="        ${dom}     nginx_http_backend;"$'\n'
    fi
done

if is_true "${CLASSIC_ENABLED:-0}"; then
    for ext_sni in "${!EXT_SNI_TO_PORT[@]}"; do
        port="${EXT_SNI_TO_PORT[$ext_sni]}"
        STREAM_MAP_RULES+="        ${ext_sni}     reality_backend_${port};"$'\n'
    done
fi

for port in "${ALL_REALITY_PORTS[@]:-}"; do
    if [ -n "$port" ]; then
        REALITY_UPSTREAMS+="
    upstream reality_backend_${port} {
        server 127.0.0.1:${port};
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

    location /dns-query/ {
        limit_req zone=doh burst=500 nodelay;
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Connection \"\";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_set_header X-Forwarded-For \$ak_real_ip;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
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
    listen unix:/dev/shm/nginx-http.sock ssl proxy_protocol;
    listen 127.0.0.1:$REALITY_FALLBACK_PORT ssl proxy_protocol;
    http2 on;
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

    # --- ЛОКАЦИЯ 3: VLESS xHTTP (Native HTTP/2 Stream-One + VLESSENC + Безотказный сокет) ---
    location ^~ ${XHTTP_STREAM_PATH} {
        if (\$request_method != POST) {
            return 404;
        }

        proxy_http_version 2;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$ak_real_ip;
        proxy_set_header X-Forwarded-For \$ak_real_ip;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # Полное отключение задержек и буферизации для сквозного H2C-потока
        proxy_request_buffering off;
        proxy_buffering off;
        tcp_nodelay on;
        proxy_socket_keepalive on;

        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        client_body_timeout 1h;
        send_timeout 1h;

        client_max_body_size 0;

        access_log off;
        error_log off;
        gzip off;

        proxy_pass http://xray_xhttp_stream;
    }

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

    # 4.1. Anti-Loop Stub Server на порту 11443 для Steal-Oneself (Zero-Leak Active Probing Shield)
    # Поглощает сканирование и активное зондирование (DPI/ЦМУ ССО) без сброса соединения (TCP RST)
    s_stub_names="${PRIMARY_DOMAIN} *.${PRIMARY_DOMAIN}"
    for s_d in "${STEAL_DOMAINS[@]:-}"; do
        [ -n "$s_d" ] && s_stub_names="${s_stub_names} ${s_d}"
    done
    cat << EOF > "/etc/nginx/conf.d/02-steal-stub.conf"
server {
    listen 127.0.0.1:11443 ssl proxy_protocol;
    http2 on;
    server_name ${s_stub_names};
    ssl_certificate ${SSL_BASE_DIR}/$PRIMARY_DOMAIN/fullchain.pem;
    ssl_certificate_key ${SSL_BASE_DIR}/$PRIMARY_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_tickets off;
    access_log off;
    location / { return 404; }
}
EOF

# 5. Генерация виртуальных хостов для дополнительных доменов
for ((i=1; i<${#ALL_DOMAINS[@]}; i++)); do
    ext_dom="${ALL_DOMAINS[$i]}"
    if [ "$ext_dom" != "$PRIMARY_DOMAIN" ] && [ "$ext_dom" != "${AGH_DOMAIN:-}" ] && [ -f "${SSL_BASE_DIR}/$ext_dom/fullchain.pem" ]; then
        cat << EOF > "/etc/nginx/conf.d/02-${ext_dom}.conf"
server {
    listen unix:/dev/shm/nginx-http.sock ssl proxy_protocol;
    listen 127.0.0.1:$REALITY_FALLBACK_PORT ssl proxy_protocol;
    http2 on;
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
upstream adguard_backend { server 127.0.0.1:3000; keepalive 32; }

server {
    listen unix:/dev/shm/nginx-http.sock ssl proxy_protocol;
    listen 127.0.0.1:$REALITY_FALLBACK_PORT ssl proxy_protocol;
    http2 on;
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

    run_with_spinner "Тестирование конфигурации и перезапуск Nginx Mainline" nginx_reload_task || die "Ошибка запуска Nginx."
    step_finish 6
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
            sed -i "/^\*nat/,/^COMMIT/{/^COMMIT/i\\-A PREROUTING -p udp --dport ${PH_RANGE} -j REDIRECT --to-ports ${HY2_PORT} # Hy2 Port Hopping
            }" /etc/ufw/before.rules
        else
            insert_before="*filter"
            grep -q '^\*mangle' /etc/ufw/before.rules 2>/dev/null && insert_before="*mangle"
            grep -q '^# TCP MSS Clamping' /etc/ufw/before.rules 2>/dev/null && insert_before="# TCP MSS Clamping"
            sed -i "/${insert_before}/i\\# Port Hopping for Hysteria 2 (added by setup_mask.sh)\n*nat\n:PREROUTING ACCEPT [0:0]\n-A PREROUTING -p udp --dport ${PH_RANGE} -j REDIRECT --to-ports ${HY2_PORT} # Hy2 Port Hopping\nCOMMIT\n" /etc/ufw/before.rules
        fi
    fi

    # 3. Персистентность через /etc/ufw/before6.rules (IPv6, секция *nat, если IPv6 включен в UFW)
    if [ -f /etc/ufw/before6.rules ] && grep -q '^IPV6=yes' /etc/default/ufw 2>/dev/null && ! grep -q "Hy2 Port Hopping" /etc/ufw/before6.rules 2>/dev/null; then
        if grep -q '^\*nat' /etc/ufw/before6.rules 2>/dev/null; then
            sed -i "/^\*nat/,/^COMMIT/{/^COMMIT/i\\-A PREROUTING -p udp --dport ${PH_RANGE} -j REDIRECT --to-ports ${HY2_PORT} # Hy2 Port Hopping
            }" /etc/ufw/before6.rules
        else
            sed -i '/^\*filter/i\# Port Hopping for Hysteria 2 - IPv6 (added by setup_mask.sh)\n*nat\n:PREROUTING ACCEPT [0:0]\n-A PREROUTING -p udp --dport '"${PH_RANGE}"' -j REDIRECT --to-ports '"${HY2_PORT}"' # Hy2 Port Hopping\nCOMMIT\n' /etc/ufw/before6.rules
        fi
    fi
fi

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
    REALITY_INBOUNDS_REPORT+="\n  ${BOLD}[Сценарий 1: Steal-Oneself (Кража у самого себя с защитой Anti-Loop)]${NC}\n"
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
    REALITY_INBOUNDS_REPORT+="\n  ${BOLD}[Сценарий 2: Classic External REALITY]${NC}\n"
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

DECOY_NAME="Локальный Front"
if [ "$DECOY_MODE" = "1" ]; then DECOY_NAME="DataSphere Analytics";
elif [ "$DECOY_MODE" = "2" ]; then DECOY_NAME="CosmosCloud NextGen";
elif [ "$DECOY_MODE" = "3" ]; then DECOY_NAME="Default Nginx Stub";
fi

# --- Шаг 7: Автоматическая настройка 3X-UI через внешний скрипт configure_3xui.sh ---
if should_skip_step 7; then
    :
elif [[ "${AUTO_SETUP_3XUI,,}" != "y" && "${AUTO_SETUP_3XUI:-}" != "1" ]]; then
    step_begin 7
    ok "Шаг 7: Автоматическая настройка 3X-UI отключена в конфигурации — пропущено."
    step_finish 7
else
    step_begin 7

    # 1. Проверяем наличие ядра 3X-UI на сервере, если нет - устанавливаем автоматически
    if ! command -v x-ui >/dev/null 2>&1 && [ ! -f /etc/x-ui/x-ui.db ] && [ ! -f /usr/local/x-ui/bin/x-ui.db ]; then
        install_3xui_core_task() {
            export DEBIAN_FRONTEND=noninteractive
            curl -Ls --connect-timeout 15 https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/install_3xui.sh
            printf "n\n" | bash /tmp/install_3xui.sh
        }
        run_with_spinner "Установка официального ядра 3X-UI (mhsanaei)" install_3xui_core_task || die "Ошибка установки ядра 3X-UI."
    fi

    # 2. Загружаем всегда самую актуальную версию configure_3xui.sh
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "/root")"
    raw_url="https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/configure_3xui.sh?v=$(date +%s)"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$raw_url" -o /tmp/configure_3xui.sh 2>/dev/null && chmod +x /tmp/configure_3xui.sh 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then
        wget -qO /tmp/configure_3xui.sh "$raw_url" 2>/dev/null && chmod +x /tmp/configure_3xui.sh 2>/dev/null || true
    fi

    CONFIG_EXEC="/tmp/configure_3xui.sh"
    [ -f "$CONFIG_EXEC" ] || CONFIG_EXEC="$script_dir/configure_3xui.sh"

    if [ -f "$CONFIG_EXEC" ]; then
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
            export AWG_PRIMARY_DNS
            export AWG_SECONDARY_DNS
            export AWG_SUBNET_IP
            export AWG_SUBNET_CIDR
            export AWG_RANDOM_TRAILERS
            bash "$CONFIG_EXEC" --config "$SAVED_CONFIG_FILE" -y
        }
        run_with_spinner "Автоматическая настройка базы 3X-UI и создание инбаундов" run_configure_3xui_task || die "Ошибка настройки базы 3X-UI."

        token_file=""
        [ -f "/run/3xui_node_token.env" ] && token_file="/run/3xui_node_token.env"
        [ -z "$token_file" ] && [ -f "/tmp/3xui_node_token.env" ] && token_file="/tmp/3xui_node_token.env"
        if [ -n "$token_file" ]; then
            source "$token_file" 2>/dev/null || true
            rm -f "$token_file" 2>/dev/null || true
            save_session_state "$SAVED_CONFIG_FILE" >/dev/null 2>&1 || true
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
        warn "Скрипт configure_3xui.sh не найден. Выполните настройку вручную."
    fi

    step_finish 7
fi

# --- Шаг 8: Приватный AdGuard Home DoH + Split-DNS (Опционально) ---
if should_skip_step 8; then
    :
elif [[ "${ENABLE_AGH,,}" != "y" && "${ENABLE_AGH:-}" != "1" ]]; then
    step_begin 8
    ok "Шаг 8: AdGuard Home DoH отключен в конфигурации — пропущено."
    step_finish 8
else
    step_begin 8

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
            local agh_arch="amd64"
            local cur_arch
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
        local agh_pass_hash=""
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
  address: 127.0.0.1:3000
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
clients:
  runtime_sources:
    whois: false
    dhcp: false
  persistent:
    - name: "Home-Router"
      ids:
        - ${AGH_CLIENT_ID}
      use_global_settings: true
access:
  allowed_clients:
    - ${AGH_CLIENT_ID}
    - 127.0.0.1
  disallowed_clients: []
  blocked_hosts: []
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
            local xui_db="/etc/x-ui/x-ui.db"
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
    step_finish 8
fi

# Итоговая проверка работоспособности ключевых сервисов (Smoke Test)
post_install_sanity_check

echo
echo -e "${GREEN}=====================================================================${NC}"
echo -e "   ИНФРАСТРУКТУРА УСПЕШНО РАЗВЕРНУТА (v7.2.0 PUBLIC EDITION)!       "
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
        echo -e "  Панель AdGuard Home:         ${CYAN}http://127.0.0.1:3000${NC} ${DIM}(SSH туннель)${NC}"
        echo -e "  Приватный DoH для роутера:   ${GREEN}https://${PRIMARY_DOMAIN}/dns-query/${AGH_CLIENT_ID}${NC}"
    fi
fi
if [[ "${ENABLE_NODE_TOKEN,,}" == "y" || "${ENABLE_NODE_TOKEN:-}" == "1" ]]; then
    echo -e "  3X-UI Node API Token:        ${GREEN}${NODE_TOKEN:-Создан в 3X-UI}${NC} (${WHITE}${NODE_TOKEN_NAME}${NC})"
fi

# Сохранение учетных данных в защищенный файл
if [ -n "${ADMIN_PASSWORD:-}" ]; then
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
API Token:             ${NODE_TOKEN:-Создан в базе 3X-UI}
Логин администратора:  ${ADMIN_USERNAME:-admin}
Пароль администратора: ${ADMIN_PASSWORD}
TLS сертификат:        Действительный (Let's Encrypt / acme.sh)
EOF_NODE_CRED
    fi
    echo "=====================================================================" >> "$CRED_FILE"
    chmod 600 "$CRED_FILE" 2>/dev/null || true
    echo -e "  ${CYAN}[i] Учетные данные сохранены в:${NC} ${BOLD}$CRED_FILE${NC} (chmod 600)"
fi
echo

echo -e "${YELLOW}[SSL] ВЫПУЩЕННЫЕ СЕРТИФИКАТЫ (Базовый путь: ${SSL_BASE_DIR}):${NC}"
echo -e "$SSL_CERT_REPORT"

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
echo -e "    * Тайминги ключей: ${CYAN}RekeyAfterTime = 120-180${NC}, ${CYAN}RekeyTimeout = 3-4${NC}, ${CYAN}RejectAfterTime = 180-210${NC}"
echo -e "    * Тайминги соединения: ${CYAN}KeepaliveTimeout = 15-20${NC}, ${CYAN}MaxHandshakeAttempts = 20-25${NC}"
echo -e "    * Переключатели: ${CYAN}RandomTrailers:${NC} ${RED}Выключить (OFF, критично для скорости!)${NC} | ${CYAN}DisableCookies:${NC} ${GREEN}Включить${NC}"
echo
fi

if [[ "${ENABLE_AWG_V2:-}" == "1" || "${ENABLE_AWG_V2,,}" == "y" ]] && [ -n "${AWG_V2_PORT:-}" ]; then
echo -e "${YELLOW}ШАГ 6: Инбаунд AmneziaWG v2.0 / Legacy (UDP $AWG_V2_PORT):${NC}"
echo -e "  - ${YELLOW}Вкладка «Основное»:${NC} Протокол: ${GREEN}amneziawg / wireguard${NC} | Адрес: ${GREEN}0.0.0.0${NC} | Порт: ${GREEN}$AWG_V2_PORT${NC} (UDP)"
echo -e "  - ${YELLOW}Вкладка «Параметры AWG» (Для роутеров Keenetic / OpenWrt и старых клиентов):${NC}"
echo -e "    * ${CYAN}H1-H4 (Строки):${NC} ${GREEN}\"149419586\", \"878791997\", \"1251051976\", \"1657628296\"${NC}"
echo -e "    * ${CYAN}HeaderProtectionKey:${NC} ${RED}ПУСТО (Выключено)${NC}"
echo -e "    * ${CYAN}Смещения (>= 12):${NC} ${GREEN}S1 = 16, S2 = 20, S3 = 24, S4 = 16${NC}"
echo -e "    * ${CYAN}Junk packets:${NC} ${GREEN}Jc = 2, Jmin = 20, Jmax = 50${NC} | ${CYAN}MTU:${NC} ${GREEN}1280${NC}"
echo
fi

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

if [[ "${ENABLE_AGH,,}" == "y" || "${ENABLE_AGH:-}" == "1" ]]; then
    local_agh_panel_url=""
    local_agh_doh_url=""
    local_server_ip="${WAN_IP:-$(curl -s4 --connect-timeout 3 icanhazip.com 2>/dev/null || echo "IP_СЕРВЕРА")}"

    if [ "${AGH_MODE:-1}" = "2" ] && [ -n "${AGH_DOMAIN:-}" ]; then
        local_agh_panel_url="https://${AGH_DOMAIN}/"
        local_agh_doh_url="https://${AGH_DOMAIN}/dns-query/${AGH_CLIENT_ID}"
    else
        local_agh_panel_url="http://127.0.0.1:3000 (доступ через SSH-туннель: ssh -L 3000:127.0.0.1:3000 user@${local_server_ip})"
        local_agh_doh_url="https://${PRIMARY_DOMAIN}/dns-query/${AGH_CLIENT_ID}"
    fi

    echo
    echo -e "${YELLOW}ШАГ 8: Приватный AdGuard Home DoH + Split-DNS:${NC}"
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
        echo -e "  - ${YELLOW}API Token:${NC}                  ${GREEN}Сгенерирован в базе 3X-UI${NC}"
    fi
    echo -e "  - ${YELLOW}Авторизация (Fallback):${NC}     Логин: ${WHITE}${ADMIN_USERNAME:-admin}${NC}, Пароль: ${YELLOW}${ADMIN_PASSWORD}${NC}"
    echo -e "  - ${YELLOW}Проверка сертификата (TLS):${NC}  ${GREEN}Включена (Действительный сертификат Let's Encrypt)${NC}"
fi
echo -e "${GREEN}=====================================================================${NC}"

# Сброс контрольной точки после успешного завершения всех этапов установки
record_step_completed 0

# Расчет общего времени выполнения скрипта
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

exit 0
