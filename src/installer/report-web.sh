# @include "installer/report-data.sh"
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
if is_true "${ENABLE_WARP:-n}"; then
    echo -e "  Cloudflare WARP Outbound:    ${GREEN}АКТИВИРОВАН (Google, Gemini, ChatGPT / MTU 1280)${NC}"
fi
if is_true "${ENABLE_AGH:-n}"; then
    if [ "${AGH_MODE:-1}" = "2" ] && [ -n "${AGH_DOMAIN:-}" ]; then
        echo -e "  Панель AdGuard Home:         ${CYAN}https://${AGH_DOMAIN}/${NC}"
        echo -e "  Приватный DoH для роутера:   ${GREEN}https://${AGH_DOMAIN}/dns-query/${AGH_CLIENT_ID}${NC}"
    else
        echo -e "  Панель AdGuard Home:         ${CYAN}http://127.0.0.1:${PORT_AGH_WEB:-3000}${NC} ${DIM}(SSH туннель)${NC}"
        echo -e "  Приватный DoH для роутера:   ${GREEN}https://${PRIMARY_DOMAIN}/dns-query/${AGH_CLIENT_ID}${NC}"
    fi
fi
if is_true "${ENABLE_NODE_TOKEN:-n}"; then
    node_scope_title="Синхронизация ноды"
    [ "${NODE_TOKEN_SCOPE:-node-sync}" = "admin" ] && node_scope_title="Администратор"
    echo -e "  3X-UI Node API Token:        ${GREEN}${NODE_TOKEN:-Не получен}${NC} (${WHITE}${NODE_TOKEN_NAME:-Node}${NC}, ${CYAN}${node_scope_title}${NC})"
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
    if is_true "${ENABLE_AGH:-n}"; then
        cat << EOF_AGH_CRED >> "$CRED_FILE"
=====================================================================
ПРИВАТНЫЙ ADGUARD HOME DOH
Логин администратора:  ${AGH_USER}
Пароль администратора: ${AGH_PASS}
URL DoH для роутера:   $([ "${AGH_MODE:-1}" = "2" ] && echo "https://${AGH_DOMAIN}/dns-query/${AGH_CLIENT_ID}" || echo "https://${PRIMARY_DOMAIN}/dns-query/${AGH_CLIENT_ID}")
EOF_AGH_CRED
    fi
    if is_true "${ENABLE_NODE_TOKEN:-n}"; then
        node_scope_title="Синхронизация ноды"
        [ "${NODE_TOKEN_SCOPE:-node-sync}" = "admin" ] && node_scope_title="Администратор"
        cat << EOF_NODE_CRED >> "$CRED_FILE"
=====================================================================
ПОДКЛЮЧЕНИЕ СЕРВЕРА КАК УЗЛА (3X-UI NODE)
Имя узла (Node Name):  ${NODE_TOKEN_NAME}
Тип ключа (Scope):    ${node_scope_title} (${NODE_TOKEN_SCOPE:-node-sync})
Адрес хоста (Host):    ${PRIMARY_DOMAIN}
Порт (Port):           443 (HTTPS через Nginx L4/L7)
Базовый путь:          ${PANEL_PATH}
API Token:             ${NODE_TOKEN:-Не получен}
Логин администратора:  ${ADMIN_USERNAME:-admin}
Пароль администратора: ${ADMIN_PASSWORD}
TLS сертификат:        Действительный (Let's Encrypt / acme.sh)
EOF_NODE_CRED
    fi
    cat << 'EOF_UNINST_CRED' >> "$CRED_FILE"
=====================================================================
КОМАНДА ДЛЯ УДАЛЕНИЯ СЕРВЕРА (ДЕИНСТАЛЛЯЦИЯ)
vpn-uninstall
(или curl -sSL "https://raw.githubusercontent.com/torrua/Nginx-L4-Stream-Router-Mask-for-3x-ui/main/uninstall.sh" | sudo bash)
EOF_UNINST_CRED
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
            local qr_out=""
            qr_out=$(/root/awg/manage-clients.sh qr client-1 2>/dev/null || true)
            if [ -n "$qr_out" ] && [[ "$qr_out" != "{"* ]]; then
                echo -e "  ${WHITE}${BOLD}QR-код для подключения первого клиента (client-1):${NC}"
                echo "$qr_out"
                echo
            fi
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

    if is_true "${ENABLE_NODE_TOKEN:-n}"; then
        echo
        echo -e "${YELLOW}ПОДКЛЮЧЕНИЕ СЕРВЕРА КАК УЗЛА (3X-UI NODE):${NC}"
        echo -e "  - ${YELLOW}Имя узла (Node Name):${NC}       ${GREEN}${NODE_TOKEN_NAME:-Node}${NC}"
        node_scope_title="Синхронизация узла (Node Sync)"
        [ "${NODE_TOKEN_SCOPE:-node-sync}" = "admin" ] && node_scope_title="Администратор (Admin)"
        echo -e "  - ${YELLOW}Область доступа (Scope):${NC}    ${CYAN}${node_scope_title}${NC}"
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
