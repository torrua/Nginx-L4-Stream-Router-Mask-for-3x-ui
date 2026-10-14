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


