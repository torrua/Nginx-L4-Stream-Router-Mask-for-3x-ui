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
  --node-token-scope <SCOPE>    Тип API-ключа ноды: node-sync (по умолчанию) или admin
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
# КОНФИГУРАЦИЯ NGINX L4 ROUTER + 3X-UI ДЛЯ SETUP.SH (__VERSION__ Universal)
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
# Публичный URL и внешний порт панели через Nginx Reverse Proxy:
# PANEL_PUBLIC_URL="https://${PRIMARY_DOMAIN}/${PANEL_PATH}/"
# PANEL_EXTERNAL_PORT="443"
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
# Изолированные подсети для предотвращения коллизий в гибридном режиме (3X-UI AWG и Standalone AWG):
AWG_SUBNET_IP="10.8.1.0"
AWG_SUBNET_CIDR="24"
AWG_STANDALONE_SUBNET_IP="10.8.0.0"
AWG_STANDALONE_SUBNET_CIDR="24"

# --- 4.1. ПРОТОКОЛЫ 3X-UI (Shadowsocks 2022 / TUIC v5 / MTProxy) ---
# Shadowsocks 2022 (L4 TCP/UDP, 2022-blake3-aes-256-gcm, инбаунд 3X-UI) [y/n]
ENABLE_SS2022="n"
SS2022_PORT="8388"

# TUIC v5 (QUIC 0-RTT, BBR Congestion Control, инбаунд 3X-UI) [y/n]
ENABLE_TUIC="n"
TUIC_PORT="8448"

# Telegram MTProxy FakeTLS (mtg-multi, инбаунд 3X-UI) [y/n]
ENABLE_MTPROTO="n"
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
# Тип (scope) API-токена ноды: node-sync (Синхронизация ноды - по умолчанию) или admin (Администратор)
NODE_TOKEN_SCOPE="node-sync"

# Автоматически обновлять ядро Xray-core до последней официальной версии с GitHub (v26.10.21+) [y/n]
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
ENABLE_HOST_SECURITY="y"
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


