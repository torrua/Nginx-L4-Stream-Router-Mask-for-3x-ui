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
# КОНФИГУРАЦИЯ NGINX L4 ROUTER + 3X-UI ДЛЯ SETUP_MASK.SH (v7.7.0 Universal)
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
# Сценарий 1: VLESS REALITY (маскировка под свой сайт с защитой Anti-Loop) [y/n]
ENABLE_STEAL="y"
STEAL_PORT="45443"
# Домены для REALITY (свой сайт, через пробел, например: "cdn.yourdomain.online")
STEAL_DOMAINS="cdn.yourdomain.online"

# Сценарий 2: VLESS REALITY (маскировка под популярные внешние сервисы) [y/n]
ENABLE_CLASSIC="y"
CLASSIC_PORT="46443"
# Внешние доверенные адреса маскировки (через пробел, например: "gateway.icloud.com")
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


